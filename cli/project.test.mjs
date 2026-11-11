import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, writeFile, mkdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { initProject, loadProject, memberFile, provision, stateDir, validate } from "./project.mjs";
import { piArguments } from "./pi.mjs";

async function project(t) {
  const root = await mkdtemp(join(tmpdir(), "agent-talk-cli-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

function broker() {
  const calls = [];
  let next = 0;
  return { calls, call: async (name, args) => {
    calls.push({ name, args });
    if (name !== "register_node") throw new Error("unexpected tool");
    return { role: args.role, node_id: args.node_id ?? "node-" + ++next,
      token: args.token ?? "test-private-" + next, ring_id: "ring-test", ring_token: "test-invitation",
      expires_in_seconds: 86400, instructions: "Test instructions" };
  } };
}

test("init is repeatable, prepares private state and preserves other MCP servers", async (t) => {
  const root = await project(t);
  await mkdir(join(root, ".pi"));
  await writeFile(join(root, ".pi/mcp.json"), JSON.stringify({ mcpServers: { other: { url: "http://localhost:5000/mcp" } } }));
  await writeFile(join(root, ".gitignore"), "existing\n");
  const config = await initProject(root, { workers: 4 });
  const before = await readFile(join(root, "agent-talk.toml"), "utf8");
  await initProject(root);
  assert.equal(await readFile(join(root, "agent-talk.toml"), "utf8"), before);
  assert.deepEqual(await loadProject(root), config);
  assert.equal((await readFile(join(root, ".gitignore"), "utf8")).match(/\/\.agent-talk\//g).length, 1);
  const mcp = JSON.parse(await readFile(join(root, ".pi/mcp.json"), "utf8"));
  assert.equal(mcp.mcpServers.other.url, "http://localhost:5000/mcp");
  assert.equal(mcp.mcpServers["agent-talk"].url, config.server);
  assert.equal((await stat(stateDir(root, config))).mode & 0o777, 0o700);
});

test("PM and four workers register privately without requiring or producing project instructions", async (t) => {
  const root = await project(t), config = await initProject(root, { workers: 4 }), client = broker();
  const pm = await provision(root, config, "pm", client);
  const invitation = JSON.parse(await readFile(join(stateDir(root, config), "invitation.json"), "utf8"));
  assert.equal(Object.hasOwn(invitation, "token"), false, "the shared invitation must not contain a PM token");
  for (const label of ["pm", "w-1", "w-2", "w-3", "w-4"]) {
    const result = label === "pm" ? pm : await provision(root, config, label, client);
    const saved = JSON.parse(await readFile(result.file, "utf8"));
    assert.equal(saved.node_id, result.member.node_id);
    assert.equal((await stat(result.file)).mode & 0o777, 0o600);
    assert.equal(Object.hasOwn(result, "prompt"), false, "transport provisioning must not author an agent prompt");
  }
  assert.equal(client.calls.length, 5);
  assert.ok(client.calls.slice(1).every(({ args }) => args.role === "worker" && args.ring_token === invitation.ring_token));
  const renewed = await provision(root, config, "w-1", client);
  assert.equal(renewed.member.node_id, "node-2");
  assert.ok(client.calls.at(-1).args.token === "test-private-2", "resume must authenticate the saved identity");
});

test("workers cannot start without their team's PM invitation", async (t) => {
  const root = await project(t), config = await initProject(root), client = broker();
  await assert.rejects(provision(root, config, "w-1", client), /Start this team's PM/);
  assert.equal(client.calls.length, 0);
});

test("expired membership rejoins the same ring; an incorrect token never triggers a fresh join", async (t) => {
  const root = await project(t), config = await initProject(root), client = broker();
  const pm = await provision(root, config, "pm", client);
  const member = await provision(root, config, "w-1", client);
  const original = client.call;
  client.call = async (name, args) => {
    if (args.node_id) throw Object.assign(new Error("Expired"), { code: "expired" });
    return original(name, args);
  };
  const rejoined = await provision(root, config, "w-1", client);
  assert.equal(rejoined.member.ring_id, pm.member.ring_id);
  assert.notEqual(rejoined.member.node_id, member.member.node_id);
  const before = await readFile(member.file, "utf8");
  client.call = async () => { throw Object.assign(new Error("Rejected"), { code: "token" }); };
  await assert.rejects(provision(root, config, "w-1", client), (e) => e.code === "token");
  assert.equal(await readFile(member.file, "utf8"), before);
});

test("invalid labels and mismatched saved roles fail before registration", async (t) => {
  const root = await project(t), config = await initProject(root), client = broker();
  await assert.rejects(provision(root, config, "../pm", client), /configured worker label/);
  await provision(root, config, "pm", client);
  await writeFile(memberFile(root, config, "w-1"), JSON.stringify({
    role: "pm", node_id: "node-other", ring_id: "ring-other", token: "test-private-other",
  }));
  await assert.rejects(provision(root, config, "w-1", client), /does not match/);
  assert.equal(client.calls.length, 1);
  for (const change of [{ team: "../other" }, { workers: 5 }, { client: "unsupported" }, { unknown: true },
    { pm_prompt: "any/path.md" }, { worker_prompt: "any/path.md" }]) {
    assert.throws(() => validate({ ...config, ...change }));
  }
});

test("Pi launch arguments configure only transport and inject no project setup or startup prompt", () => {
  const file = "/project/.agent-talk/delivery/pm.json", server = "http://127.0.0.1:4000/mcp";
  const args = piArguments(file, server);
  assert.equal(args.length, 6);
  assert.equal(args[0], "-e");
  assert.deepEqual(args.slice(2), ["--agent-talk-membership", file, "--agent-talk-url", server]);
  assert.ok(!args.includes("--"), "a positional startup prompt must not be appended");
  assert.doesNotMatch(args.join(" "), /AGENTS\.md|\.claude|SKILL\.md|system-prompt/);
});

test("the init executable prints five complete shell-safe launch commands", async (t) => {
  const root = await project(t);
  const file = fileURLToPath(new URL("./agent-talk.mjs", import.meta.url));
  const result = spawnSync(process.execPath, [file, "init", "--client", "pi", "--workers", "4"], {
    cwd: root, encoding: "utf8",
  });
  assert.equal(result.status, 0);
  const commands = result.stdout.split("\n").filter((line) => line.startsWith("cd "));
  assert.equal(commands.length, 5);
  for (const [n, command] of commands.entries()) {
    assert.ok(command.includes(root) && command.includes(file));
    assert.ok(command.endsWith("start " + (n === 0 ? "pm" : "w-" + n)));
    assert.equal(spawnSync("/bin/sh", ["-n"], { input: command }).status, 0);
  }
});

test("an expired PM with a missing invitation cannot accidentally create a new ring", async (t) => {
  const root = await project(t), config = await initProject(root);
  await writeFile(memberFile(root, config, "pm"), JSON.stringify({
    role: "pm", node_id: "node-old", ring_id: "ring-old", token: "test-only-private",
  }));
  let calls = 0;
  const client = { call: async () => { calls++; throw Object.assign(new Error("Expired"), { code: "expired" }); } };
  await assert.rejects(provision(root, config, "pm", client), /lacks its invitation/);
  assert.equal(calls, 1, "no role-only PM registration may follow an expired saved membership");
});
