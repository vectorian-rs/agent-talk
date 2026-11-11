import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { McpClient, readMembership } from "../polling/mcp.mjs";

const [executable = "pi"] = process.argv.slice(2);
const root = fileURLToPath(new URL("../", import.meta.url));
const directory = await mkdtemp(join(tmpdir(), "agent-talk-pi-smoke-"));
const processes = [];
const diagnostics = [];
const requests = new WeakMap();
let serial = 0;
const auth = (member) => ({ node_id: member.node_id, token: member.token });
let stage = "registration";
let broker, url;

async function until(check, message, timeout = 15_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    assert.ok(diagnostics.every((item) => item.errors === 0), "Pi tool or model failed.");
    await delay(50);
  }
  throw new Error(message);
}

function rpc(index, command) {
  const child = processes[index], pending = requests.get(child), id = "check-" + ++serial;
  let timer;
  const result = new Promise((resolve, reject) => {
    timer = setTimeout(() => reject(new Error("Pi command timed out")), 15_000);
    pending.set(id, (response) => response.success ? resolve(response.data) :
      reject(new Error("Pi command failed; response omitted")));
    child.stdin.write(JSON.stringify({ ...command, id }) + "\n");
  });
  return result.finally(() => { clearTimeout(timer); pending.delete(id); });
}

const exists = (file) => access(file).then(() => true, () => false);

async function startBroker(config) {
  broker = spawn("mix", ["run", "--no-compile", "--no-halt", "--", "--config", config], {
    cwd: join(root, ".."), stdio: "ignore",
  });
  broker.on("error", () => {});
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    assert.ok(broker.exitCode === null && broker.signalCode === null, "Isolated broker exited.");
    try {
      const response = await fetch(new URL("/", url), { signal: AbortSignal.timeout(500) });
      await response.body?.cancel();
      if (response.ok) return;
    } catch { /* Wait for this owned listener. */ }
    await delay(50);
  }
  throw new Error("Isolated broker did not start.");
}

async function stopProcess(child) {
  if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
  const closed = new Promise((resolve) => child.once("close", resolve));
  child.kill("SIGTERM");
  await Promise.race([closed, delay(5000)]);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
    await closed;
  }
}

async function launch(file, role, invitation) {
  const child = spawn(executable, [
    "--mode", "rpc", "--no-session", "--no-extensions", "--approve",
    "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files",
    "-e", "builtin:mcp",
    "-e", join(root, "pi/agent-talk.ts"),
    "-e", join(root, "pi/test-fixtures/smoke-provider.ts"),
    "--provider", "agent-talk-smoke", "--model", "smoke",
    "--tools", "smoke_mail,mcp__agent_talk__*",
    "--agent-talk-membership", file, "--agent-talk-url", url,
    "--agent-talk-smoke-role", role,
    ...(invitation ? ["--agent-talk-smoke-invitation", invitation] : []),
  ], {
    cwd: directory, stdio: ["pipe", "pipe", "pipe"],
    // Keep test Pi configuration separate from the operator's real MCP servers.
    env: { ...process.env, PI_CODING_AGENT_DIR: join(directory, "pi-config-" + processes.length) },
  });
  processes.push(child);
  const diagnostic = { starts: 0, tools: 0, errors: 0, stderr_bytes: 0, running: false,
    aborted: 0, cancelling: false, cancelledRun: false, cancelledTool: null, heldTool: null,
    error_kinds: [], status: "", notice: "" };
  diagnostics.push(diagnostic);
  requests.set(child, new Map());
  let ready = false, failed = false, buffer = "";
  child.on("error", () => { failed = true; });
  child.on("exit", () => { failed = true; });
  // Never print raw subprocess output; tool arguments can contain credentials.
  child.stderr.on("data", (chunk) => { diagnostic.stderr_bytes += chunk.length; });
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      try {
        const event = JSON.parse(line);
        if (event.type === "response") requests.get(child).get(event.id)?.(event);
        if (event.type === "response" && event.id === "ready") ready = event.success;
        if (event.type === "agent_start") {
          diagnostic.starts++; diagnostic.running = true; diagnostic.cancelledRun = false;
        }
        if (event.type === "agent_settled") {
          diagnostic.running = false;
          if (event.aborted) diagnostic.aborted++;
        }
        if (event.type === "tool_execution_start" && event.toolName === "smoke_mail" &&
            event.args?.action === "hold") diagnostic.heldTool = event.toolCallId;
        if (event.type === "extension_ui_request" && event.method === "setStatus" &&
            event.statusKey === "agent-talk") diagnostic.status = event.statusText ?? "";
        if (event.type === "extension_ui_request" && event.method === "notify") diagnostic.notice = event.message;
        if (event.type === "tool_execution_end") {
          diagnostic.tools++;
          if (event.isError && !diagnostic.cancelling && event.toolCallId !== diagnostic.cancelledTool) {
            diagnostic.errors++;
            diagnostic.error_kinds.push({ source: "tool", tool: event.toolName });
          }
        }
        if (event.type === "message_end" && event.message?.errorMessage && event.message.stopReason !== "aborted" &&
            !(diagnostic.cancelledRun && /aborted|cancelled/i.test(event.message.errorMessage))) {
          diagnostic.errors++;
          diagnostic.error_kinds.push({ source: "message", reason: event.message.stopReason });
        }
      } catch { /* A non-protocol diagnostic is not a command response. */ }
    }
  });
  child.stdin.write(JSON.stringify({ id: "ready", type: "get_commands" }) + "\n");
  for (let n = 0; n < 200 && !ready && !failed; n++) await delay(50);
  assert.ok(ready && !failed, "Pi did not start; check that Pi 1.5+ is installed.");
  child.stdin.write(JSON.stringify({ type: "prompt", message: "Register for the smoke test" }) + "\n");
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const member = await readMembership(file);
    if (member) {
      const saved = JSON.parse(await readFile(file, "utf8"));
      assert.ok(saved.structuredContent?.node_id, "Pi must save the real MCP result envelope.");
      return member;
    }
    assert.ok(!failed && diagnostic.errors === 0, "Pi registration failed.");
    await delay(50);
  }
  throw new Error("Pi did not save its registration.");
}

async function collected(file, count) {
  try {
    const result = JSON.parse(await readFile(file + ".received", "utf8"));
    return result.length === count ? result : null;
  } catch { return null; }
}

try {
  stage = "starting isolated broker";
  const probe = createServer();
  await new Promise((resolve, reject) => { probe.once("error", reject); probe.listen(0, "127.0.0.1", resolve); });
  const port = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));
  url = "http://127.0.0.1:" + port + "/mcp";
  const config = join(directory, "server.toml");
  await writeFile(config, 'port = ' + port + '\nnode_ttl_seconds = 86400\nmessage_history_limit = 50\nmembership_file = "memberships.json"\nhistory_file = "history.sqlite3"\n');
  await startBroker(config);
  await mkdir(join(directory, ".pi"));
  await writeFile(join(directory, ".pi/mcp.json"), JSON.stringify({
    mcpServers: { "agent-talk": { url, exposure: "direct" } },
  }));
  const client = new McpClient(url);
  stage = "Pi registration";
  const files = [0, 1, 2].map((n) => join(directory, "member-" + n + ".json"));
  const pm = await launch(files[0], "pm");
  const invitation = join(directory, "invitation.json");
  await writeFile(invitation, JSON.stringify({ ring_token: pm.ring_token }), { mode: 0o600 });
  const workers = [];
  for (const file of files.slice(1)) {
    workers.push(await launch(file, "worker", invitation));
  }
  await until(() => diagnostics.every((item) => !item.running), "Registration did not settle");
  stage = "cancelled turn and continuing presence";
  await rpc(1, { type: "prompt", message: "hold smoke" });
  await until(() => exists(files[1] + ".busy"), "Worker did not enter held turn");
  const before = (await client.call("list_nodes", auth(pm))).nodes.find((node) => node.node_id === workers[0].node_id).last_seen;
  diagnostics[1].cancelling = true;
  diagnostics[1].cancelledRun = true;
  diagnostics[1].cancelledTool = diagnostics[1].heldTool;
  await rpc(1, { type: "abort" });
  await until(() => diagnostics[1].aborted > 0 && !diagnostics[1].running, "Worker cancellation did not settle");
  diagnostics[1].cancelling = false;
  await until(async () => (await client.call("list_nodes", auth(pm))).nodes
    .find((node) => node.node_id === workers[0].node_id).last_seen > before,
  "Cancelled worker stopped heartbeats");
  await until(() => diagnostics[1].status.includes("automatic turns paused"), "Cancellation status did not update");
  console.log("PASS: cancelling a real Pi turn pauses wake-ups while authenticated heartbeats continue.");
  for (const round of [1, 2]) {
    if (round === 2) {
      stage = "multiline command and extension reload";
      await until(() => !diagnostics[1].running, "Worker did not settle before reload");
      await rpc(1, { type: "prompt", message: "/agent-talk on\n/agent-talk status" });
      assert.ok(diagnostics[1].notice.includes("one command at a time"));
      await rpc(1, { type: "prompt", message: "/agent-talk status" });
      assert.ok(diagnostics[1].notice.includes(files[1]), "Multiline command changed the membership path");
      await rpc(1, { type: "prompt", message: "/smoke-bad-binding" });
      await rpc(1, { type: "prompt", message: "/smoke-reload" });
      await rpc(1, { type: "prompt", message: "/agent-talk status" });
      assert.ok(diagnostics[1].notice.includes(files[1]), "Reload did not restore the explicit launch binding");
      stage = "server process restart";
      const previousPid = broker.pid;
      const counter = JSON.parse(await readFile(join(directory, "memberships.json"), "utf8")).next_id;
      await stopProcess(broker);
      await startBroker(config);
      assert.notEqual(broker.pid, previousPid);
      const restored = await client.call("list_nodes", auth(pm));
      assert.deepEqual(restored.nodes.map((node) => node.node_id).sort(),
        [pm, ...workers].map((node) => node.node_id).sort());
      const renewed = await client.call("register_node", { ...auth(pm), role: "pm" });
      assert.ok(renewed.token === pm.token && renewed.ring_token === pm.ring_token,
        "Server restart must preserve credentials and invitations.");
      const newcomer = await client.call("register_node", { role: "observer", ring_token: pm.ring_token,
        project: basename(directory), name: basename(directory) + " / observer" });
      assert.equal(newcomer.ring_id, pm.ring_id, "Saved invitations must still admit new members.");
      assert.ok(Number(newcomer.node_id.split("-")[1]) > counter,
        "IDs issued after a full process restart must advance the saved counter.");
      stage = "busy worker and explicit monitoring off";
      await rpc(1, { type: "prompt", message: "hold smoke" });
      await until(() => exists(files[1] + ".busy"), "Worker did not enter held turn");
      await rpc(2, { type: "prompt", message: "/agent-talk off" });
    }
    processes[0].stdin.write(JSON.stringify({ type: "prompt", message: "assign smoke" }) + "\n");

    if (round === 1) {
      stage = "cancelled worker resumes on a human prompt";
      await until(() => collected(files[2], 1), "Idle worker did not receive assignment", 30_000);
      assert.ok(!await collected(files[1], 1), "Cancelled worker restarted without operator input");
      await rpc(1, { type: "prompt", message: "resume smoke" });
    } else {
      await until(() => diagnostics[1].status.includes("turn requested"), "Busy worker did not queue notification", 30_000);
      assert.ok(!await collected(files[2], 2), "Explicit off did not stop wake-ups");
      await writeFile(files[1] + ".release", "1");
      await rpc(2, { type: "prompt", message: "/agent-talk on" });
    }

    stage = round === 1 ? "automatic assignment and replies" : "automatic replies after server restart";
    let responses;
    const deadline = Date.now() + 90_000;
    while (Date.now() < deadline) {
      responses = await collected(files[0], round * 2);
      if (responses) break;
      assert.ok(diagnostics.every((item) => item.errors === 0), "Pi tool or model failed.");
      assert.ok(processes.every((child) => child.exitCode === null), "A Pi session exited.");
      await delay(100);
    }
    assert.ok(responses, "PM did not automatically collect both worker results.");
    assert.deepEqual(responses.slice(-2).map((message) => message.from).sort(),
      workers.map((worker) => worker.node_id).sort());
    assert.ok(responses.every((message) => message.message === "done: smoke"));
    for (const file of files.slice(1)) {
      const messages = await collected(file, round);
      assert.ok(messages && messages.at(-1).from === pm.node_id, "Worker did not collect the PM assignment.");
    }
  }
  const inbox = await client.call("list_nodes", auth(pm));
  assert.ok(inbox.nodes.every((node) => node.pending_messages === 0));
  assert.ok(inbox.nodes.every((node) => node.project === basename(directory) &&
    node.name.startsWith(basename(directory) + " / ")), "Pi must announce repository and agent labels.");
  console.log("PASS: three actual Pi processes woke from idle, workers received and replied, PM collected both results.");
  console.log("PASS: server process restarted; the same Pi sessions and saved identities exchanged another assignment and replies.");
  console.log("PASS: cancelled-turn recovery, malformed-command rejection, reload, busy follow-up and explicit on/off used real Pi lifecycle paths.");
  console.log("PASS: Pi MCP registration, saved envelopes, automatic wake-up and MCP replies; no paid API calls or printed credentials.");
} catch {
  console.error("FAIL at " + stage + "; details omitted to protect credentials.");
  console.error(JSON.stringify(diagnostics.map(({ status, notice, ...counts }) => counts)));
  process.exitCode = 1;
} finally {
  for (const child of processes) child.stdin.end();
  await Promise.all(processes.map(async (child) => {
    for (let n = 0; n < 40 && child.exitCode === null; n++) await delay(50);
    await stopProcess(child);
  }));
  await stopProcess(broker);
  await rm(directory, { recursive: true, force: true });
}
