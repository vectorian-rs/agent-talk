import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import agentTalk from "./agent-talk.ts";

function runtime(directory, flags = {}) {
  const hooks = {}, commands = {}, entries = [], messages = [];
  const ctx = {
    cwd: directory, hasUI: false,
    sessionManager: { getSessionId: () => "pi-session", getBranch: () => entries },
  };
  const api = {
    registerFlag: (name, spec) => { if (!(name in flags)) flags[name] = spec.default; },
    getFlag: (name) => flags[name],
    on: (name, handler) => { hooks[name] = handler; },
    registerCommand: (name, spec) => { commands[name] = spec.handler; },
    appendEntry: (customType, data) => {
      entries.push({ type: "custom", customType, data });
    },
    sendMessage: (message, options) => { messages.push({ message, options }); },
  };
  agentTalk(api);
  return { ctx, api, hooks, commands, entries, messages, flags };
}

test("optional integration waits for registration and persists only session settings", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-talk-pi-"));
  const r = runtime(dir, { "agent-talk-membership": ".agent-talk/pm.json" });
  try {
    await r.hooks.session_start({ reason: "startup" }, r.ctx);
    assert.equal(r.messages.length, 0);
    assert.equal(r.entries[0].data.file, join(dir, ".agent-talk/pm.json"));
    assert.equal(r.entries[0].data.url, "http://127.0.0.1:4000/mcp");
    assert.equal(Object.hasOwn(r.entries[0].data, "token"), false);
    await r.commands["agent-talk"]("off", r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, false);
    await r.hooks.session_start({ reason: "reload" }, r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, false);
  } finally {
    r.hooks.session_shutdown();
    await rm(dir, { recursive: true });
  }
});

test("new and forked Pi sessions never inherit the original membership flag", async () => {
  const r = runtime("/tmp", { "agent-talk-membership": "parent.json" });
  for (const reason of ["new", "fork", "reload", "resume"]) {
    await r.hooks.session_start({ reason }, r.ctx);
    assert.equal(r.entries.length, 0);
  }
  r.hooks.session_shutdown();
});

test("cancellation keeps monitoring enabled; explicit off survives reload without changing history", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-talk-pi-"));
  const r = runtime(dir);
  try {
    await r.hooks.session_start({ reason: "startup" }, r.ctx);
    assert.equal(r.entries.length, 0);
    await r.commands["agent-talk"]("on .agent-talk/worker.json", r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, true);
    const count = r.entries.length;
    await r.hooks.agent_settled({ aborted: true });
    assert.equal(r.entries.length, count);
    assert.equal(r.entries.at(-1).data.enabled, true);
    await r.hooks.session_start({ reason: "reload" }, r.ctx);
    await r.commands["agent-talk"]("off", r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, false);
    assert.equal(r.entries[0].data.enabled, true, "later commands must not mutate earlier session entries");
    await r.hooks.session_start({ reason: "reload" }, r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, false);
    await r.commands["agent-talk"]("on", r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, true);
  } finally {
    r.hooks.session_shutdown();
    await rm(dir, { recursive: true });
  }
});

test("status explains a saved-registration error instead of showing only its file path", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-talk-pi-status-"));
  const file = join(dir, "worker.json");
  const r = runtime(dir, { "agent-talk-membership": file });
  const notices = [];
  r.ctx.hasUI = true;
  r.ctx.ui = { setStatus() {}, notify(message) { notices.push(message); } };
  try {
    await writeFile(file, "{}", { mode: 0o600 });
    await r.hooks.session_start({ reason: "startup" }, r.ctx);
    // Session start no longer waits for the first check; let it finish.
    for (let n = 0; n < 20; n++) await new Promise(setImmediate);
    await r.commands["agent-talk"]("status", r.ctx);
    assert.match(notices.at(-1), /successful register_node result/);
    assert.ok(notices.at(-1).includes(file));
  } finally {
    r.hooks.session_shutdown();
    await rm(dir, { recursive: true, force: true });
  }
});

test("pasted commands cannot replace the configured membership path", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-talk-pi-command-"));
  const r = runtime(dir, { "agent-talk-membership": ".agent-talk/w-1.json" });
  const notices = [];
  r.ctx.hasUI = true;
  r.ctx.ui = { setStatus() {}, notify(message) { notices.push(message); } };
  try {
    await r.hooks.session_start({ reason: "startup" }, r.ctx);
    const count = r.entries.length;
    for (const input of ["on\n/agent-talk status", "on\r\n/agent-talk status"]) {
      await r.commands["agent-talk"](input, r.ctx);
      assert.equal(r.entries.length, count, "invalid input must not overwrite saved settings");
      assert.match(notices.at(-1), /one command at a time/);
    }
    for (const input of ["on /agent-talk status", "off extra", "status extra", "unknown"]) {
      await r.commands["agent-talk"](input, r.ctx);
      assert.equal(r.entries.length, count, "invalid commands must leave saved settings intact");
    }
    await r.commands["agent-talk"]("on", r.ctx);
    assert.equal(r.entries.at(-1).data.file, join(dir, ".agent-talk/w-1.json"));
  } finally {
    r.hooks.session_shutdown();
    await rm(dir, { recursive: true, force: true });
  }
});

test("a human prompt resumes automatic turns after cancellation while checks continue", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "agent-talk-pi-resume-"));
  const file = join(dir, "worker.json");
  let checks = 0;
  t.mock.method(globalThis, "fetch", async (_url, options) => {
    const request = JSON.parse(options.body);
    if (request.method === "notifications/initialized") return new Response(null, { status: 202 });
    if (request.method === "tools/call") checks++;
    const result = request.method === "initialize" ? { protocolVersion: "2025-11-25" } :
      { structuredContent: { ring_id: "ring-test", inbox: { pending_messages: 1, next_message_id: "m-1" } } };
    return Response.json({ jsonrpc: "2.0", id: request.id, result });
  });
  const r = runtime(dir, { "agent-talk-membership": file });
  const notices = [];
  r.ctx.hasUI = true;
  r.ctx.ui = { setStatus() {}, notify(message) { notices.push(message); } };
  try {
    await writeFile(file, JSON.stringify({
      node_id: "node-test", token: "test-only-private", ring_id: "ring-test", role: "worker",
    }));
    await r.hooks.session_start({ reason: "startup" }, r.ctx);
    // Session start and settling no longer wait for checks; let them finish.
    for (let n = 0; n < 20 && r.messages.length === 0; n++) await new Promise(setImmediate);
    assert.equal(r.messages.length, 1);
    assert.match(r.messages[0].message.content, /session's existing instructions/);
    assert.doesNotMatch(r.messages[0].message.content, /claims|acceptance|assigns the next|AGENTS\.md|\.claude/);
    const before = checks;
    await r.hooks.agent_settled({ aborted: true });
    for (let n = 0; n < 20 && checks === before; n++) await new Promise(setImmediate);
    assert.ok(checks > before, "cancelled model turns must not stop presence checks");
    assert.equal(r.messages.length, 1, "cancellation must not immediately restart work");
    await r.commands["agent-talk"]("status", r.ctx);
    assert.match(notices.at(-1), /automatic turns paused/);
    assert.match(notices.at(-1), /Last successful check: \d{4}-/);
    await r.hooks.before_agent_start({ messageType: "custom" }, r.ctx);
    assert.equal(r.messages.length, 1);
    await r.hooks.before_agent_start({ messageType: "user" }, r.ctx);
    for (let n = 0; n < 20 && r.messages.length === 1; n++) await new Promise(setImmediate);
    assert.equal(r.messages.length, 2);
    await r.commands["agent-talk"]("off", r.ctx);
    await r.hooks.before_agent_start({ messageType: "user" }, r.ctx);
    assert.equal(r.messages.length, 2, "a prompt must not override an explicit off");
  } finally {
    r.hooks.session_shutdown();
    await rm(dir, { recursive: true, force: true });
  }
});

test("reload repairs an invalid saved path from this session's explicit launch binding", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-talk-pi-binding-"));
  const r = runtime(dir, { "agent-talk-membership": ".agent-talk/w-1.json" });
  r.entries.push({ type: "custom", customType: "agent-talk-inbox-settings", data: {
    file: "/agent-talk status", url: "http://127.0.0.1:4000/mcp", session: "pi-session", enabled: true,
  } });
  try {
    await r.hooks.session_start({ reason: "reload" }, r.ctx);
    assert.equal(r.entries.at(-1).data.file, join(dir, ".agent-talk/w-1.json"));
    assert.equal(r.entries.at(-1).data.enabled, true);
    assert.equal(r.entries[0].data.file, "/agent-talk status", "repair must preserve earlier history");
  } finally {
    r.hooks.session_shutdown();
    await rm(dir, { recursive: true, force: true });
  }
});
