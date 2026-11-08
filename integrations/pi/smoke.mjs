import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { McpClient } from "../polling/mcp.mjs";

const [url, executable = "pi"] = process.argv.slice(2);
if (!url) throw new Error("Run through mix run --no-start examples/pi_smoke.exs");
const root = fileURLToPath(new URL("../", import.meta.url));
const directory = await mkdtemp(join(tmpdir(), "agent-talk-pi-smoke-"));
const processes = [];
const diagnostics = [];
const secrets = [];
const auth = (member) => ({ node_id: member.node_id, token: member.token });
let stage = "registration";

async function launch(file) {
  const child = spawn(executable, [
    "--mode", "rpc", "--no-session", "--no-extensions", "--no-mcp",
    "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files",
    "-e", join(root, "pi/agent-talk.ts"),
    "-e", join(root, "pi/test-fixtures/smoke-provider.ts"),
    "--provider", "agent-talk-smoke", "--model", "smoke", "--tools", "smoke_mail",
    "--agent-talk-membership", file, "--agent-talk-url", url,
  ], { cwd: directory, stdio: ["pipe", "pipe", "pipe"] });
  processes.push(child);
  const diagnostic = { starts: 0, tools: 0, errors: [], stderr: "" };
  diagnostics.push(diagnostic);
  let ready = false, failed = false, buffer = "";
  child.on("error", () => { failed = true; });
  child.on("exit", () => { failed = true; });
  // Never print raw subprocess output; tool arguments can contain credentials.
  child.stderr.on("data", (chunk) => { diagnostic.stderr += chunk; });
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      try {
        const event = JSON.parse(line);
        if (event.type === "response" && event.id === "ready") ready = event.success;
        if (event.type === "agent_start") diagnostic.starts++;
        if (event.type === "tool_execution_end") {
          diagnostic.tools++;
          if (event.isError) diagnostic.errors.push(
            event.result?.content?.filter((item) => item.type === "text").map((item) => item.text)
              .join("\n") || "Tool failed");
        }
        if (event.type === "message_end" && event.message?.errorMessage) {
          diagnostic.errors.push(event.message.errorMessage);
        }
      } catch { /* A non-protocol diagnostic is not a command response. */ }
    }
  });
  child.stdin.write(JSON.stringify({ id: "ready", type: "get_commands" }) + "\n");
  for (let n = 0; n < 200 && !ready && !failed; n++) await delay(50);
  assert.ok(ready && !failed, "Pi did not start; check that Pi 1.5+ is installed.");
}

async function collected(file, count) {
  try {
    const result = JSON.parse(await readFile(file + ".received", "utf8"));
    return result.length === count ? result : null;
  } catch { return null; }
}

try {
  const client = new McpClient(url);
  const pm = await client.call("register_node", { role: "pm" });
  const workers = [];
  for (let n = 0; n < 2; n++) {
    workers.push(await client.call("register_node", { role: "worker", ring_token: pm.ring_token }));
  }
  const members = [pm, ...workers];
  for (const member of members) secrets.push(member.token, member.ring_token);
  stage = "starting Pi";
  const files = [];
  for (const [n, member] of members.entries()) {
    const file = join(directory, "member-" + n + ".json");
    await writeFile(file, JSON.stringify(member), { mode: 0o600 });
    files.push(file);
    await launch(file);
  }
  await client.call("communicate", { ...auth(pm), action: "send",
    to: workers.map((worker) => worker.node_id), message: "pick up smoke" });

  stage = "automatic assignment and replies";
  let responses;
  const deadline = Date.now() + 40_000;
  while (Date.now() < deadline) {
    responses = await collected(files[0], 2);
    if (responses) break;
    assert.ok(diagnostics.every((item) => item.errors.length === 0), "Pi tool or model failed.");
    assert.ok(processes.every((child) => child.exitCode === null), "A Pi session exited.");
    await delay(100);
  }
  assert.ok(responses, "PM did not automatically collect both worker results.");
  assert.deepEqual(responses.map((message) => message.from).sort(),
    workers.map((worker) => worker.node_id).sort());
  assert.ok(responses.every((message) => message.message === "done: smoke"));
  for (const file of files.slice(1)) {
    const messages = await collected(file, 1);
    assert.ok(messages && messages[0].from === pm.node_id, "Worker did not collect the PM assignment.");
  }
  const inbox = await client.call("list_nodes", auth(pm));
  assert.ok(inbox.nodes.every((node) => node.pending_messages === 0));
  console.log("PASS: three actual Pi processes woke from idle, workers received and replied, PM collected both results.");
  console.log("PASS: real MCP/tool/lifecycle paths; deterministic local model, no paid API calls or printed credentials.");
} catch {
  console.error("FAIL at " + stage + "; details omitted to protect credentials.");
  let safe = JSON.stringify(diagnostics);
  for (const secret of secrets) safe = safe.replaceAll(secret, "[redacted]");
  console.error(safe);
  process.exitCode = 1;
} finally {
  for (const child of processes) child.stdin.end();
  await Promise.all(processes.map(async (child) => {
    for (let n = 0; n < 40 && child.exitCode === null; n++) await delay(50);
    if (child.exitCode === null) child.kill("SIGTERM");
  }));
  await rm(directory, { recursive: true, force: true });
}
