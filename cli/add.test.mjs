import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, writeFile, mkdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";
import { addAgent, agentClient, initProject, labels, loadProject, memberFile, provision, savePrivate, stateDir, validate } from "./project.mjs";
import { claudeArguments } from "./claude.mjs";
import { acquireSession } from "./session.mjs";

async function project(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), "agent-talk-add '"));
  t.after(() => rm(root, { recursive: true, force: true }));
  return { root, config: await initProject(root, { workers: 4, ...options }) };
}
const pm = { role: "pm", node_id: "node-pm", token: "test-pm-secret", ring_id: "ring-existing", ring_token: "test-ring-secret" };
const invitation = { pm_id: pm.node_id, ring_id: pm.ring_id, ring_token: pm.ring_token };
const cli = fileURLToPath(new URL("./agent-talk.mjs", import.meta.url));
const json = async (file) => JSON.parse(await readFile(file, "utf8"));
const verifiedPM = { ring_id: pm.ring_id, nodes: [pm], inbox: { pending_messages: 0, next_message_id: null } };

async function seed(root, config) {
  await savePrivate(memberFile(root, config, "pm"), pm);
}

test("add adopts a manual team's PM and preserves existing memberships and configuration", async (t) => {
  const { root, config } = await project(t, { team: "manual-4" });
  await seed(root, config);
  const existing = memberFile(root, config, "w-1");
  await writeFile(existing, "existing worker bytes\n");
  const calls = [];
  const client = { call: async (name, args) => { calls.push({ name, args }); return verifiedPM; } };
  const updated = await addAgent(root, "cc-w5", { client: "claude" }, client);
  assert.deepEqual(updated, { ...config, agents: { "cc-w5": { client: "claude" } } });
  assert.deepEqual(await loadProject(root), updated);
  assert.equal(agentClient(updated, "w-1"), "pi");
  assert.equal(agentClient(updated, "cc-w5"), "claude");
  assert.equal(labels(updated).length, 6);
  assert.equal(await readFile(existing, "utf8"), "existing worker bytes\n");
  assert.deepEqual(await json(memberFile(root, config, "pm")), pm);
  assert.deepEqual(calls, [{ name: "list_nodes", args: { node_id: pm.node_id, token: pm.token } }]);
  const file = join(stateDir(root, config), "invitation.json");
  assert.deepEqual(await json(file), invitation);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const before = await readFile(join(root, "agent-talk.toml"), "utf8");
  await addAgent(root, "cc-w5", {}, client);
  assert.equal(await readFile(join(root, "agent-talk.toml"), "utf8"), before);
  assert.equal(calls.length, 1, "repeating add must not register or renew any identity");
  await assert.rejects(addAgent(root, "cc-w5", { client: "pi" }, client), /different client/);
});

test("adding arbitrary workers has no four-worker ceiling and does not create a PM", async (t) => {
  const { root, config } = await project(t);
  await savePrivate(join(stateDir(root, config), "invitation.json"), invitation);
  const client = { call: async () => { throw new Error("add must not register an agent"); } };
  let updated;
  for (const label of ["cc-w5", "cc-w6", "cc-w7", "cc-w8", "reviewer", "w-9"]) {
    updated = await addAgent(root, label, { client: label === "w-9" ? "pi" : "claude" }, client);
  }
  updated = await addAgent(root, "another-pi", {}, client);
  assert.equal(agentClient(updated, "another-pi"), "pi");
  assert.equal(labels(updated).length, 12);
  const calls = [];
  const result = await provision(root, updated, "cc-w8", { call: async (name, args) => {
    calls.push({ name, args });
    return { ...pm, node_id: "node-new", token: "test-worker-secret", role: "worker" };
  } });
  assert.equal(result.pmId, pm.node_id);
  assert.deepEqual(calls, [{ name: "register_node", args: {
    role: "worker", ring_token: pm.ring_token, project: config.project, name: config.project + " / cc-w8",
  } }]);
  assert.equal((await json(result.file)).ring_id, pm.ring_id);
});

test("missing, expired, invalid or mismatched PM state never creates a replacement ring", async (t) => {
  const { root, config } = await project(t);
  const before = await readFile(join(root, "agent-talk.toml"), "utf8");
  let calls = 0;
  const client = { call: async () => { calls++; return { ring_id: "other", nodes: [] }; } };
  await assert.rejects(addAgent(root, "cc-w5", { client: "claude" }, client), /Start this team's PM/);
  assert.equal(calls, 0);
  await seed(root, config);
  await assert.rejects(addAgent(root, "cc-w5", { client: "claude" }, client), /could not be verified/);
  assert.equal(calls, 1);
  await assert.rejects(addAgent(root, "cc-w5", { client: "claude" }, {
    call: async () => { throw Object.assign(new Error("expired"), { code: "expired" }); },
  }), (error) => error.code === "expired");
  await writeFile(join(stateDir(root, config), "invitation.json"), "malformed");
  await assert.rejects(addAgent(root, "cc-w5", { client: "claude" }, client), /Cannot read the team invitation/);
  assert.equal(calls, 1, "a corrupt invitation must not silently fall back to another ring");
  assert.equal(await readFile(join(root, "agent-talk.toml"), "utf8"), before);
});

test("invalid labels, reserved names, client changes and incompatible init options fail safely", async (t) => {
  const { root, config } = await project(t);
  for (const label of ["pm", "invitation", "../escape", "", "x".repeat(65)]) {
    await assert.rejects(addAgent(root, label, { client: "claude" }, {}), /worker label/);
  }
  for (const agents of [{ invitation: { client: "pi" } }, { x: { client: "other" } }, { x: { client: "claude", prompt: "ignored" } }]) {
    assert.throws(() => validate({ ...config, agents }));
  }
  await assert.rejects(initProject(root, { team: "other" }), /differs from init options/);
  assert.equal((await loadProject(root)).team, config.team);
});

test("concurrent additions fail explicitly instead of losing a config update", async (t) => {
  const { root, config } = await project(t);
  await seed(root, config);
  let entered, finish;
  const waiting = new Promise((resolve) => { entered = resolve; });
  const gate = new Promise((resolve) => { finish = resolve; });
  const client = { call: async () => { entered(); await gate; return verifiedPM; } };
  const first = addAgent(root, "first", { client: "claude" }, client);
  await waiting;
  try {
    await assert.rejects(addAgent(root, "second", { client: "claude" }, client), /Another add is in progress/);
  } finally { finish(); }
  await first;
  await addAgent(root, "second", { client: "claude" }, client);
  assert.deepEqual(Object.keys((await loadProject(root)).agents), ["first", "second"]);
});

test("an added worker cannot overwrite saved credentials with a foreign-ring registration", async (t) => {
  const { root, config } = await project(t);
  await savePrivate(join(stateDir(root, config), "invitation.json"), invitation);
  const updated = await addAgent(root, "cc-w5", { client: "claude" }, {});
  const file = memberFile(root, updated, "cc-w5");
  const saved = { ...pm, node_id: "node-worker", role: "worker" };
  await savePrivate(file, saved);
  await assert.rejects(provision(root, updated, "cc-w5", {
    call: async () => ({ ...saved, ring_id: "wrong-ring" }),
  }), /Invalid registration response/);
  assert.deepEqual(await json(file), saved);
});

test("Claude files bind only this worker, preserve existing settings, and contain no bearer credentials", async (t) => {
  const { root, config } = await project(t);
  await mkdir(join(root, ".claude"));
  const existing = join(root, ".claude/settings.json");
  await writeFile(existing, "{\"existing\":true}\n");
  const file = memberFile(root, config, "cc-w5");
  const args = await claudeArguments({ file, server: config.server, label: "cc-w5", pmId: pm.node_id });
  const value = (flag) => args[args.indexOf(flag) + 1];
  assert.equal(value("--name"), "cc-w5");
  assert.equal(await readFile(existing, "utf8"), "{\"existing\":true}\n");
  const mcp = await json(value("--mcp-config"));
  assert.deepEqual(mcp, { mcpServers: { "agent-talk": { type: "http", url: config.server } } });
  const settings = await json(value("--settings"));
  for (const event of ["SessionStart", "UserPromptSubmit"]) {
    const command = settings.hooks[event][0].hooks[0].command;
    assert.match(command, /inbox/);
    assert.equal((await run("/bin/sh", ["-n"], { input: command })).code, 0);
  }
  const binding = await json(join(file + ".claude", "transport.json"));
  assert.equal(binding.membership_file, file);
  assert.equal(binding.pm_id, pm.node_id);
  assert.ok(binding.instructions.some((line) => line.includes("do not wake an idle")));
  const output = JSON.stringify({ args, mcp, settings, binding });
  assert.ok(!output.includes(pm.token) && !output.includes(pm.ring_token));
  assert.equal((await stat(value("--settings"))).mode & 0o777, 0o600);
});

test("session ownership prevents duplicate launches and can be released", async (t) => {
  const { root, config } = await project(t);
  const release = await acquireSession(root, config, "w-1");
  await assert.rejects(acquireSession(root, config, "w-1"), /Session already owned/);
  await release();
  await (await acquireSession(root, config, "w-1"))();
});

async function run(command, args, { cwd, env, input } = {}) {
  const child = spawn(command, args, { cwd, env, stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", (data) => { stdout += data; });
  child.stderr.on("data", (data) => { stderr += data; });
  child.stdin.end(input);
  const [code] = await once(child, "close");
  return { code, stdout, stderr };
}

test("CLI add and start launch only the requested Claude worker and resume it without rejoining", async (t) => {
  const calls = [];
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
    else {
      calls.push(body.params);
      const args = body.params.arguments;
      result = { structuredContent: body.params.name === "list_nodes" ? verifiedPM : {
        ...pm, role: "worker", node_id: args.node_id ?? "node-worker", token: "test-worker-secret",
      } };
    }
    res.writeHead(200, { "content-type": "application/json", "mcp-session-id": "test-session" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: body.id, result }));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const { root, config } = await project(t, { team: "manual-4", server: `http://127.0.0.1:${server.address().port}/mcp` });
  await seed(root, config);
  const bin = join(root, "bin");
  await mkdir(bin);
  await writeFile(join(bin, "claude"), `#!${process.execPath}\nrequire('node:fs').writeFileSync(process.env.CAPTURE, JSON.stringify(process.argv.slice(2)));\nif (process.env.HOLD) { process.on('SIGTERM', () => process.exit(0)); setInterval(() => {}, 1000); }\n`, { mode: 0o700 });
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH, CAPTURE: join(root, "launch.json") };
  const added = await run(process.execPath, [cli, "add", "cc-w5", "--client", "claude"], { cwd: root, env });
  assert.equal(added.code, 0, added.stderr);
  assert.match(added.stdout, /start cc-w5/);
  for (let n = 0; n < 2; n++) {
    const started = await run(process.execPath, [cli, "start", "cc-w5"], { cwd: root, env });
    assert.equal(started.code, 0, started.stderr);
    assert.match(started.stdout, /idle sessions are not automatically awakened/);
    for (const secret of [pm.token, pm.ring_token, "test-worker-secret"]) assert.ok(!started.stdout.includes(secret));
    const args = await json(env.CAPTURE);
    assert.equal(args[args.indexOf("--name") + 1], "cc-w5");
    assert.ok(!JSON.stringify(args).includes("test-worker-secret"));
  }
  assert.equal(calls.filter((call) => call.name === "register_node").length, 2);
  assert.equal(calls[1].arguments.role, "worker");
  assert.equal(calls[1].arguments.ring_token, pm.ring_token);
  assert.equal(calls[2].arguments.node_id, "node-worker");
  assert.equal(calls[2].arguments.token, "test-worker-secret");
  assert.deepEqual(await json(memberFile(root, config, "pm")), pm);
  const launch = await json(env.CAPTURE);
  const settings = await json(launch[launch.indexOf("--settings") + 1]);
  const hook = await run("/bin/sh", ["-c", settings.hooks.UserPromptSubmit[0].hooks[0].command], { cwd: root, env });
  assert.equal(hook.code, 0, hook.stderr);
  assert.match(hook.stdout, /inbox empty for node-worker/);
  assert.equal(calls.at(-1).name, "list_nodes");
  assert.ok(calls.every((call) => call.name !== "communicate"), "hooks must not drain mail");
  // A long-lived client owns its membership until it exits, including on SIGTERM.
  await rm(env.CAPTURE);
  const held = spawn(process.execPath, [cli, "start", "cc-w5"], {
    cwd: root, env: { ...env, HOLD: "1" }, stdio: "ignore",
  });
  t.after(() => { if (held.exitCode === null) held.kill("SIGTERM"); });
  const closed = once(held, "close");
  let ready = false;
  for (let n = 0; n < 100; n++) {
    if (await stat(env.CAPTURE).then(() => true, () => false)) { ready = true; break; }
    await delay(20);
  }
  assert.ok(ready, "fake Claude must start");
  const beforeDuplicate = calls.length;
  const duplicate = await run(process.execPath, [cli, "start", "cc-w5"], { cwd: root, env });
  assert.notEqual(duplicate.code, 0);
  assert.match(duplicate.stderr, /Session already owned/);
  assert.equal(calls.length, beforeDuplicate, "duplicate launch must fail before contacting the broker");
  held.kill("SIGTERM");
  assert.equal((await closed)[0], 0);
  await (await acquireSession(root, config, "cc-w5"))();
  // A missing executable must release ownership too.
  await rm(join(bin, "claude"));
  const failed = await run(process.execPath, [cli, "start", "cc-w5"], { cwd: root, env: { ...env, PATH: bin } });
  assert.notEqual(failed.code, 0);
  await (await acquireSession(root, config, "cc-w5"))();
});
