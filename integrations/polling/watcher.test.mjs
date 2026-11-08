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
    client: { call: async (name, args, signal) => {
      calls.push({ name, args, signal });
      if (state.error) throw state.error;
      if (state.wait) await state.wait;
      return { ring_id: state.member.ring_id, inbox: { ...state.inbox } };
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

test("missing credentials wait quietly; cancellation pauses rather than restarting work", async () => {
  const f = fixture();
  f.state.member = null;
  await f.watcher.start();
  assert.equal(f.statuses.at(-1).state, "waiting");
  assert.equal(f.calls.length, 0);
  await f.watcher.settled(true);
  await f.watcher.check();
  assert.equal(f.events.length, 0);
  assert.equal(f.statuses.at(-1).state, "paused");
});

test("an older server or a ring mismatch never causes an inbox wake", async () => {
  const f = fixture();
  f.state.inbox = undefined;
  await f.watcher.start();
  assert.equal(f.statuses.at(-1).state, "error");
  assert.equal(f.events.length, 0);
  f.watcher.stop();
});
