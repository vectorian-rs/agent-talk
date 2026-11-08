import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
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
      entries.push({ type: "custom", customType, data: structuredClone(data) });
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

test("explicit on/off and cancellation are session scoped and survive reload", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-talk-pi-"));
  const r = runtime(dir);
  try {
    await r.hooks.session_start({ reason: "startup" }, r.ctx);
    assert.equal(r.entries.length, 0);
    await r.commands["agent-talk"]("on .agent-talk/worker.json", r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, true);
    await r.hooks.agent_settled({ aborted: true });
    assert.equal(r.entries.at(-1).data.enabled, false);
    await r.hooks.session_start({ reason: "reload" }, r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, false);
    await r.commands["agent-talk"]("on", r.ctx);
    assert.equal(r.entries.at(-1).data.enabled, true);
  } finally {
    r.hooks.session_shutdown();
    await rm(dir, { recursive: true });
  }
});
