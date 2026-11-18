import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, writeFile, mkdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";
import { allocateAgent, launchCommand } from "./dynamic.mjs";
import { savePrivate } from "./project.mjs";

const pm = { role: "pm", node_id: "node-pm", token: "test-pm-secret", ring_id: "ring-existing", ring_token: "test-ring-secret" };
const cli = fileURLToPath(new URL("./agent-talk.mjs", import.meta.url));
const json = async (file) => JSON.parse(await readFile(file, "utf8"));
const options = { team: "manual-4", client: "claude" };

async function project(t, seed = true) {
  const root = await mkdtemp(join(tmpdir(), "agent-talk-add '"));
  t.after(() => rm(root, { recursive: true, force: true }));
  if (seed) {
    await mkdir(join(root, ".agent-talk/manual-4"), { recursive: true });
    await savePrivate(join(root, ".agent-talk/manual-4/pm.json"), pm);
  }
  return root;
}
function broker() {
  const calls = [];
  return { calls, call: async (name, args) => {
    calls.push({ name, args });
    return name === "list_nodes" ? { ring_id: pm.ring_id, nodes: [pm], inbox: { pending_messages: 0, next_message_id: null } } :
      { ...pm, role: "worker", node_id: "node-" + calls.length, token: "test-worker-secret" };
  } };
}

test("add uses only the explicit folder, saves one worker, and prints a native command", async (t) => {
  const root = await project(t), client = broker();
  // A project-level TOML, even a broken one, is irrelevant to this path.
  await writeFile(join(root, "agent-talk.toml"), "not valid TOML");
  await writeFile(join(root, ".agent-talk/manual-4/w-1.json"), "existing worker bytes");
  const launch = await allocateAgent(root, "cc-w5", options, async () => client);
  assert.equal(launch.client, "claude");
  assert.match(launchCommand(root, launch), /&& claude /);
  assert.deepEqual(client.calls.map((call) => call.name), ["list_nodes", "register_node"]);
  assert.equal(client.calls[1].args.role, "worker");
  assert.equal(client.calls[1].args.ring_token, pm.ring_token);
  assert.equal(await readFile(join(root, "agent-talk.toml"), "utf8"), "not valid TOML");
  assert.equal(await readFile(join(root, ".agent-talk/manual-4/w-1.json"), "utf8"), "existing worker bytes");
  assert.deepEqual(await json(join(root, ".agent-talk/manual-4/pm.json")), pm);
  const invitation = await json(join(root, ".agent-talk/manual-4/invitation.json"));
  assert.deepEqual(invitation, { pm_id: pm.node_id, ring_id: pm.ring_id, ring_token: pm.ring_token });
  const member = join(root, ".agent-talk/manual-4/cc-w5.json");
  assert.equal((await json(member)).ring_id, pm.ring_id);
  assert.equal((await stat(member)).mode & 0o777, 0o600);
  const args = launch.args;
  const settings = await json(args[args.indexOf("--settings") + 1]);
  const mcp = await json(args[args.indexOf("--mcp-config") + 1]);
  const binding = await json(join(member + ".claude", "transport.json"));
  assert.equal(binding.membership_file, member);
  assert.equal(binding.pm_id, pm.node_id);
  assert.ok(binding.instructions.some((line) => line.includes("do not wake an idle")));
  const publicOutput = JSON.stringify({ launch, settings, mcp, binding });
  for (const secret of [pm.token, pm.ring_token, "test-worker-secret"]) assert.ok(!publicOutput.includes(secret));
  const count = client.calls.length;
  await assert.rejects(allocateAgent(root, "cc-w5", options, async () => client), /already has a membership/);
  assert.equal(client.calls.length, count, "repeating add must not take over a live identity");
});

test("there is no roster, count or project config to update", async (t) => {
  const root = await project(t), client = broker();
  for (const label of ["cc-w5", "cc-w6", "cc-w7", "cc-w8", "reviewer"]) {
    await allocateAgent(root, label, options, async () => client);
  }
  const pi = await allocateAgent(root, "w-9", { ...options, client: "pi" }, async () => client);
  assert.equal(pi.client, "pi");
  assert.ok(pi.args.includes("--agent-talk-membership"));
  assert.equal(client.calls.filter((call) => call.name === "register_node").length, 6);
  await assert.rejects(stat(join(root, "agent-talk.toml")), { code: "ENOENT" });
});

test("no guessing: team, label and client must be explicit, and a missing ring is not created", async (t) => {
  const root = await project(t, false);
  const connect = async () => { throw new Error("must not connect"); };
  for (const [label, opts] of [
    ["cc-w5", { client: "claude" }], ["cc-w5", { team: "manual-4" }],
    ["../escape", options], ["pm", options], ["invitation", options],
    ["cc-w5", { ...options, team: "../escape" }],
  ]) await assert.rejects(allocateAgent(root, label, opts, connect));
  await assert.rejects(allocateAgent(root, "cc-w5", options, connect), /never creates a ring/);
  await mkdir(join(root, ".agent-talk/manual-4"), { recursive: true });
  await assert.rejects(allocateAgent(root, "cc-w5", options, connect), /never creates a ring/);
});

test("invalid PM state and simultaneous allocations fail without replacing the ring", async (t) => {
  const root = await project(t);
  await assert.rejects(allocateAgent(root, "cc-w5", options, async () => ({
    call: async () => ({ ring_id: "other", nodes: [] }),
  })), /could not be verified/);
  await assert.rejects(stat(join(root, ".agent-talk/manual-4/cc-w5.json")), { code: "ENOENT" });
  await writeFile(join(root, ".agent-talk/manual-4/allocation.lock"), "");
  await assert.rejects(allocateAgent(root, "cc-w5", options), /Another allocation/);
  assert.deepEqual(await json(join(root, ".agent-talk/manual-4/pm.json")), pm);
});

async function run(command, args, { cwd, env } = {}) {
  const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", (data) => { stdout += data; });
  child.stderr.on("data", (data) => { stderr += data; });
  const [code] = await once(child, "close");
  return { code, stdout, stderr };
}

test("CLI needs no init and prints a working native Claude command without launching it", async (t) => {
  const client = broker();
  const server = createServer(async (req, res) => {
    let input = "";
    for await (const chunk of req) input += chunk;
    const body = JSON.parse(input);
    if (body.method === "notifications/initialized") { res.writeHead(202).end(); return; }
    let result;
    if (body.method === "initialize") result = { protocolVersion: "2025-11-25" };
    else if (body.method === "tools/list") result = { tools: [
      { name: "register_node", inputSchema: { required: ["role"], properties: { ring_token: { type: "string" } } } },
      { name: "list_nodes" }, { name: "communicate" },
    ] };
    else result = { structuredContent: await client.call(body.params.name, body.params.arguments) };
    res.writeHead(200, { "content-type": "application/json", "mcp-session-id": "test-session" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: body.id, result }));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const root = await project(t);
  const bin = join(root, "bin");
  await mkdir(bin);
  await writeFile(join(bin, "claude"), `#!${process.execPath}\nrequire('node:fs').writeFileSync(process.env.CAPTURE, JSON.stringify(process.argv.slice(2)));\n`, { mode: 0o700 });
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH, CAPTURE: join(root, "launch.json") };
  const added = await run(process.execPath, [cli, "add", "cc-w5", "--team", "manual-4", "--client", "claude", "--server", `http://127.0.0.1:${server.address().port}/mcp`], { cwd: root, env });
  assert.equal(added.code, 0, added.stderr);
  await assert.rejects(stat(env.CAPTURE), { code: "ENOENT" }, "add must not launch Claude");
  const command = added.stdout.split("\n").find((line) => line.startsWith("cd "));
  assert.match(command, /&& claude /);
  for (const secret of [pm.token, pm.ring_token, "test-worker-secret"]) assert.ok(!added.stdout.includes(secret));
  const launched = await run("/bin/sh", ["-c", command], { cwd: root, env });
  assert.equal(launched.code, 0, launched.stderr);
  const args = await json(env.CAPTURE);
  assert.equal(args[args.indexOf("--name") + 1], "cc-w5");
  const settings = await json(args[args.indexOf("--settings") + 1]);
  const hook = await run("/bin/sh", ["-c", settings.hooks.UserPromptSubmit[0].hooks[0].command], { cwd: root, env });
  assert.equal(hook.code, 0, hook.stderr);
  assert.match(hook.stdout, /inbox empty/);
  assert.equal(client.calls.at(-1).name, "list_nodes");
  assert.ok(client.calls.every((call) => call.name !== "communicate"), "hooks must not receive mail");
});
