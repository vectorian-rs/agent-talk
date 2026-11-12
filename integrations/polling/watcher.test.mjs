import assert from "node:assert/strict";
import test from "node:test";
import { ClientError } from "./mcp.mjs";
import { InboxWatcher } from "./watcher.mjs";

function fixture() {
  const events = [], statuses = [], timers = [], calls = [];
  const member = { node_id: "n-1", token: "test-only-private", ring_id: "r-1", role: "worker" };
  const state = { member, inbox: { pending_messages: 0, next_message_id: null } };
  const watcher = new InboxWatcher({
    loadMembership: async () => state.member,
    client: { call: async (name, args, signal, timeoutMs) => {
      calls.push({ name, args, signal, timeoutMs });
      if (state.error) throw state.error;
      if (state.wait) await state.wait;
      return { ring_id: state.member.ring_id, inbox: { ...state.inbox },
        ...(state.waited === undefined ? {} : { waited_seconds: state.waited }) };
    } },
    wake: (event) => { events.push(event); },
    status: (status) => { statuses.push(status); },
    setTimer: (callback, delay) => { timers.push({ callback, delay }); return timers.length; },
    clearTimer: () => {},
  });
  return { watcher, state, events, statuses, timers, calls };
}

test("empty polling only checks metadata, renews membership and never wakes a model", async () => {
  const f = fixture();
  await f.watcher.start();
  await f.watcher.check();
  assert.equal(f.events.length, 0);
  assert.deepEqual(f.calls.map((call) => call.name), ["list_nodes", "list_nodes"]);
  assert.equal(f.timers.at(-1).delay, 10_000);
  f.watcher.stop();
});

test("inbox checks announce the caller's display labels without changing authentication", async () => {
  const f = fixture();
  f.watcher.labels = { project: "hiko", name: "hiko / w-1" };
  await f.watcher.start();
  assert.equal(f.calls[0].args.project, "hiko");
  assert.equal(f.calls[0].args.name, "hiko / w-1");
  assert.equal(f.calls[0].args.node_id, f.state.member.node_id);
  assert.ok(f.calls[0].args.token === f.state.member.token, "labels must preserve authentication");
  assert.equal(f.events.length, 0);
  f.watcher.stop();
});

test("labels confirmed at registration override host-derived fallback labels", async () => {
  const f = fixture();
  f.state.member = { ...f.state.member, project: "hiko", name: "hiko / w-1" };
  f.watcher.labels = { project: "directory-name", name: "directory-name / w-1" };
  await f.watcher.start();
  assert.equal(f.calls[0].args.project, "hiko");
  assert.equal(f.calls[0].args.name, "hiko / w-1");
  f.watcher.stop();
});

test("a server-echoed node_id name is not a label and keeps the host fallback", async () => {
  const f = fixture();
  f.state.member = { ...f.state.member, project: null, name: f.state.member.node_id };
  f.watcher.labels = { project: "directory-name", name: "directory-name / w-1" };
  await f.watcher.start();
  assert.equal(f.calls[0].args.project, "directory-name");
  assert.equal(f.calls[0].args.name, "directory-name / w-1");
  f.watcher.stop();
});

test("one outstanding wake, then new mail is picked up after the busy agent settles", async () => {
  const f = fixture();
  f.state.inbox = { pending_messages: 1, next_message_id: "m-1" };
  await f.watcher.start();
  await f.watcher.check();
  assert.equal(f.events.length, 1);
  f.state.inbox = { pending_messages: 1, next_message_id: "m-2" };
  await f.watcher.check();
  assert.equal(f.events.length, 1);
  await f.watcher.settled();
  assert.equal(f.events.length, 2);
  assert.equal(JSON.stringify(f.events).includes(f.state.member.token), false);
  f.state.inbox = { pending_messages: 0, next_message_id: null };
  await f.watcher.settled();
  assert.equal(f.events.length, 2);
  f.watcher.stop();
});

test("unread mail has bounded model retries; a new head message resets the budget", async () => {
  const f = fixture();
  f.state.inbox = { pending_messages: 1, next_message_id: "m-1" };
  await f.watcher.start();
  for (let n = 0; n < 5; n++) await f.watcher.settled();
  assert.equal(f.events.length, 3);
  assert.equal(f.statuses.at(-1).state, "stalled");
  f.state.inbox.next_message_id = "m-2";
  await f.watcher.check();
  assert.equal(f.events.length, 4);
  f.watcher.stop();
});

test("checks ask the server to hold the reply and extend the HTTP timeout to match", async () => {
  const f = fixture();
  await f.watcher.start();
  assert.equal(f.calls[0].args.wait_seconds, 25);
  assert.equal(f.calls[0].timeoutMs, 30_000);
  f.watcher.stop();
});

test("an empty held reply resumes the watch immediately; anything else keeps pacing", async () => {
  const f = fixture();
  f.state.waited = 25;
  await f.watcher.start();
  assert.equal(f.timers.at(-1).delay, 0);
  await f.watcher.check();
  assert.equal(f.timers.at(-1).delay, 0);
  f.watcher.stop();

  for (const shape of [
    { inbox: { pending_messages: 1, next_message_id: "m-1" }, waited: 25 },
    { inbox: { pending_messages: 0, next_message_id: null }, waited: 0 },
    { inbox: { pending_messages: 0, next_message_id: null }, waited: undefined },
  ]) {
    const g = fixture();
    g.state.inbox = shape.inbox;
    g.state.waited = shape.waited;
    await g.watcher.start();
    assert.equal(g.timers.at(-1).delay, 10_000);
    g.watcher.stop();
  }
});

test("paused and stalled watchers keep interval pacing despite held replies", async () => {
  const f = fixture();
  f.state.waited = 25;
  await f.watcher.start();
  await f.watcher.settled(true);
  assert.equal(f.statuses.at(-1).state, "paused");
  assert.equal(f.timers.at(-1).delay, 10_000);
  f.watcher.stop();

  const g = fixture();
  g.state.inbox = { pending_messages: 1, next_message_id: "m-1" };
  g.state.waited = 0;
  await g.watcher.start();
  for (let n = 0; n < 5; n++) await g.watcher.settled();
  assert.equal(g.statuses.at(-1).state, "stalled");
  assert.equal(g.timers.at(-1).delay, 10_000);
  g.watcher.stop();
});

test("errors keep their backoff even after held replies were seen", async () => {
  const f = fixture();
  f.state.waited = 25;
  await f.watcher.start();
  assert.equal(f.timers.at(-1).delay, 0);
  f.state.error = new ClientError("transport", "Unavailable");
  await f.watcher.check();
  assert.equal(f.timers.at(-1).delay, 20_000);
  f.watcher.stop();
});

test("transient failures back off without model turns, then recover automatically", async () => {
  const f = fixture();
  f.state.error = new ClientError("transport", "Unavailable");
  await f.watcher.start();
  assert.equal(f.timers.at(-1).delay, 20_000);
  await f.watcher.check();
  assert.equal(f.timers.at(-1).delay, 40_000);
  await f.watcher.check();
  assert.equal(f.timers.at(-1).delay, 60_000);
  delete f.state.error;
  await f.watcher.check();
  assert.equal(f.timers.at(-1).delay, 10_000);
  assert.equal(f.events.length, 0);
  f.watcher.stop();
});

test("auth failure requests recovery once; a saved replacement identity resumes watching", async () => {
  const f = fixture();
  f.state.error = new ClientError("expired", "Expired");
  await f.watcher.start();
  await f.watcher.settled();
  await f.watcher.check();
  assert.deepEqual(f.events, [{ kind: "recovery" }]);
  delete f.state.error;
  f.state.member = { ...f.state.member, node_id: "n-2", token: "replacement-test-only" };
  f.state.inbox = { pending_messages: 1, next_message_id: "m-new" };
  await f.watcher.check();
  assert.equal(f.events.length, 2);
  assert.equal(f.events.at(-1).node_id, "n-2");
  f.watcher.stop();
});

test("stop aborts in-flight checks and suppresses late wake-ups", async () => {
  const f = fixture();
  let release;
  f.state.wait = new Promise((resolve) => { release = resolve; });
  f.state.inbox = { pending_messages: 1, next_message_id: "m-1" };
  const checking = f.watcher.start();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.watcher.check(), checking);
  f.watcher.stop();
  assert.equal(f.calls[0].signal.aborted, true);
  release();
  await checking;
  assert.equal(f.events.length, 0);
  assert.equal(f.timers.length, 0);
});

test("missing credentials are checked promptly without making network requests", async () => {
  const f = fixture();
  f.state.member = null;
  await f.watcher.start();
  assert.equal(f.statuses.at(-1).state, "waiting");
  assert.equal(f.calls.length, 0);
  assert.equal(f.timers.at(-1).delay, 250);
  f.watcher.stop();
});

test("cancellation pauses automatic turns while metadata checks continue; resume handles queued mail", async () => {
  const f = fixture();
  f.state.inbox = { pending_messages: 1, next_message_id: "m-1" };
  await f.watcher.start();
  await f.watcher.settled(true);
  await f.watcher.check();
  assert.equal(f.calls.length, 3);
  assert.equal(f.events.length, 1);
  assert.equal(f.statuses.at(-1).state, "paused");
  await f.watcher.resume();
  assert.equal(f.events.length, 2);
  f.watcher.stop();
});

test("a short saved lease adjusts the heartbeat interval", async () => {
  const f = fixture();
  f.state.member.expires_in_seconds = 1;
  await f.watcher.start();
  assert.ok(f.timers.at(-1).delay < 500);
  f.state.member.expires_in_seconds = 86400;
  await f.watcher.check();
  assert.equal(f.timers.at(-1).delay, 10000);
  f.watcher.stop();
});

test("failed wake-up callbacks retry without losing mail or exhausting successful-turn retries", async () => {
  const f = fixture();
  let attempts = 0;
  f.state.inbox = { pending_messages: 1, next_message_id: "m-1" };
  f.watcher.wake = async () => { attempts++; throw new Error("host failed with private data"); };
  await f.watcher.start();
  for (let n = 0; n < 4; n++) await f.watcher.check();
  assert.equal(attempts, 5);
  assert.equal(f.statuses.at(-1).state, "error");
  assert.ok(!JSON.stringify(f.statuses).includes("private data"));
  f.watcher.wake = (event) => { f.events.push(event); };
  await f.watcher.check();
  assert.equal(f.events.length, 1);
  assert.equal(f.timers.at(-1).delay, 10000);
  f.watcher.stop();
});

test("a failed recovery wake-up is handled and retried", async () => {
  const f = fixture();
  f.state.error = new ClientError("expired", "Expired");
  f.watcher.wake = async () => { throw new Error("host failed"); };
  await f.watcher.start();
  f.watcher.wake = (event) => { f.events.push(event); };
  await f.watcher.check();
  await f.watcher.check();
  assert.deepEqual(f.events, [{ kind: "recovery" }]);
  f.watcher.stop();
});

test("an older server or a ring mismatch never causes an inbox wake", async () => {
  const f = fixture();
  f.state.inbox = undefined;
  await f.watcher.start();
  assert.equal(f.statuses.at(-1).state, "error");
  assert.equal(f.events.length, 0);
  f.watcher.stop();
});

test("malformed inbox metadata and foreign ring responses never trigger a turn", async () => {
  for (const result of [
    { ring_id: "other-ring", inbox: { pending_messages: 1, next_message_id: "m-1" } },
    { ring_id: "r-1", inbox: { pending_messages: 0, next_message_id: "m-1" } },
    { ring_id: "r-1", inbox: { pending_messages: 1, next_message_id: "" } },
    { ring_id: "r-1", inbox: { pending_messages: -1, next_message_id: null } },
  ]) {
    const f = fixture();
    f.watcher.client.call = async () => result;
    await f.watcher.start();
    assert.equal(f.events.length, 0);
    assert.equal(f.statuses.at(-1).state, "error");
    f.watcher.stop();
  }
});

test("stopping during an asynchronous wake suppresses late status updates", async () => {
  const f = fixture();
  f.state.inbox = { pending_messages: 1, next_message_id: "m-1" };
  let finish;
  f.watcher.wake = () => new Promise((resolve) => { finish = resolve; });
  const checking = f.watcher.start();
  await new Promise(setImmediate);
  f.watcher.stop();
  const count = f.statuses.length;
  finish();
  await checking;
  assert.equal(f.statuses.length, count);
  assert.equal(f.timers.length, 0);
});
