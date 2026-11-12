# Plan: long-poll inbox watching (`wait_seconds`)

Status: implemented on top of inbox recovery (#6); independent of reply
references (#5). Adds timer and concurrency handling without changing which
messages agents can receive; plain `list_nodes` replies stay byte-identical.

## Problem

Delivery latency is bounded by the watcher's polling interval
(`integrations/polling/watcher.mjs`, `intervalMs = 10_000`). Each empty
check also makes a round trip. The hub serializes everything through one
GenServer (`lib/agent_talk/hub.ex`), so it knows the instant a message is
enqueued; a caller should be able to park until that instant.

## Simplest solution

One optional field on `list_nodes`: `wait_seconds`. If the caller's inbox is
empty, the hub holds the request until a message arrives, the caller expires,
or the wait elapses, then returns the normal `list_nodes` payload. Non-empty
inboxes return immediately, as today.

Only replies to requests that carried `wait_seconds` gain `waited_seconds`
(the effective wait granted, `0` when the inbox was non-empty). Replies to
plain `list_nodes` calls stay byte-identical to today's. No capability
detection is needed: Anubis validates tool args with Peri in strict mode,
which **drops** unknown keys, so an old server strips `wait_seconds` and
replies immediately without `waited_seconds` — and the watcher's single
scheduling rule below then falls back to interval pacing automatically.

Effective wait is `min(wait_seconds, 25, ttl_ms / 2000)` seconds, clamped on
the server only: under common 30s proxy timeouts and well inside the lease,
so a parked healthy node never expires mid-wait. Values above the cap are
clamped; non-numeric or negative values are `invalid_request`.

### Hub mechanism (the whole of it)

- State gains `waiters :: %{node_id => {from, timer_ref, args}}` — at most
  one per node. Use
  `:erlang.start_timer(wait_ms, self(), {:waiter_timeout, node_id})`; its
  returned timer reference identifies that park. A second park releases the
  first and cancels its timer before replacing it. The effective wait is
  recomputed from `args` and `state.ttl_ms` wherever needed, never stored.
- `dispatch({:list, args}, ...)` returns a new `{:park, node_id, wait_ms}`
  shape when the wait applies. `handle_call` runs the normal
  `persist → record → notify` pipeline (the park already renewed the lease and
  applied labels via `authenticate/3`), starts the timer, stores the waiter
  and returns `{:noreply, persisted}`.
- **Waking is re-dispatch, not a parallel reply path**: to wake a waiter, run
  its stored args minus `wait_seconds` back through `dispatch({:list, ...})`
  and `GenServer.reply` with the result, setting `waited_seconds` to the
  recomputed effective wait rather than the immediate re-dispatch's zero.
  Cancel the timer when releasing the waiter. No second payload builder is
  needed; the field reports the original grant even on an early wake.
- **One wake function, no touched send path**: `wake_ready_waiters(state)`
  runs at the end of `handle_call` and the `:sweep` branch of `handle_info`.
  For each waiter: node gone → reply `{:error, :expired, @missing_node_error}`;
  inbox non-empty → re-dispatch and reply; otherwise keep waiting. The send
  branch of `communicate/3` is not modified at all. The wake predicate is
  hardwired to "own inbox non-empty"; if a future caller needs to watch for
  something else (membership changes, say), extend this predicate behind an
  explicit `wait_for` argument rather than forking a second parking
  mechanism.
- `{:timeout, timer_ref, {:waiter_timeout, node_id}}` in `handle_info`: act
  only if the current waiter has that exact timer reference; otherwise
  ignore the stale event.
  Timer cancellation alone is insufficient because its message may already
  be queued. For a matching waiter, re-dispatch, reply and drop it. State
  changes from re-dispatch flow through existing presence persistence.

### Plumbing

- `Hub.list_nodes/2` (hub.ex:20) passes `wait_ms + 5_000` as the
  `GenServer.call` timeout when args carry `wait_seconds`; default otherwise.
- `lib/agent_talk/tools/list_nodes.ex`: add the schema field and one moduledoc
  sentence.
- `integrations/polling/mcp.mjs`: `request/4` hard-codes
  `AbortSignal.timeout(15_000)`; make the timeout a per-call option that
  `call()` forwards. Use `wait_ms + 5_000` for watches; other calls keep
  their current timeout.
- Invariant, not a change: the watcher already owns a separate `McpClient`
  and MCP session from the main agent
  (`integrations/pi/agent-talk.ts:41`) and must keep it — Anubis serializes
  requests within a session, so sharing one would hold the agent's
  send/receive behind a parked watch.
- `integrations/polling/watcher.mjs`: every check requests a flat
  `wait_seconds = 25`; the server clamp is the single authority on the grant
  (no client-side copy of the formula), and the 30s HTTP timeout exceeds any
  clamped grant. Schedule by outcome, one rule: an empty reply with
  `waited_seconds > 0` starts the next check immediately; anything else —
  non-empty inbox, `waited_seconds == 0`, or a reply without the field (old
  server) — keeps the ordinary heartbeat interval, including busy, paused and
  stalled agents. Repeated immediate replies must not spin.
- Missing membership keeps the 250ms check; errors keep existing backoff.
  Existing stop, cancellation, wake budgeting and settled checks still apply.

## Deliberately cut

- Blocking `communicate receive` (the watcher never drains mail; agents drain
  only when woken, so a blocking receive has no consumer today).
- Waiter "kinds" and per-waiter payload builders.
- All capability detection and negotiation: support is inferred per reply
  from `waited_seconds`, and old servers drop the unknown arg (verified
  against Peri's strict mode, which filters rather than rejects).
- A client-side copy of the wait clamp — the watcher asks for 25 and takes
  what it is granted.

## Acceptance criteria

1. **Gate (write this test first)**: over real HTTP in `mcp_test.exs`, a
   dedicated watcher session parks with `wait_seconds: 10`. Other sessions
   still send and receive in < 2s; a send to the watched node unblocks its
   metadata check in < 2s. This tests concurrency across sessions, not within
   one. If independent sessions block, stop and redesign.
2. With no send, a parked call returns an empty payload after the effective
   wait with `waited_seconds > 0`. Drive the timeout with a small injected
   `ttl_ms` (the `ttl_ms / 2000` clamp keeps the real wait at tens of
   milliseconds) or by injecting the timer message directly — no
   seconds-scale sleeps.
3. A non-empty inbox returns immediately with `waited_seconds == 0`.
4. Node expiry during a park replies with error code `expired`, driven by
   advancing the injected clock past the TTL and sending `:sweep`, not by
   sleeping.
5. A second park from the same node releases the first immediately. Inject
   the old timeout after replacement: it must neither reply to nor remove
   the new waiter. A matching timeout or send releases the new waiter once;
   no waiter leaks remain.
6. A call without `wait_seconds` returns a byte-identical reply to today's
   (no `waited_seconds` key); `wait_seconds: "x"` or `-1` is
   `invalid_request`.
7. Watcher (fake timers): an empty waited reply schedules immediately; a
   non-empty or unwaited reply keeps interval pacing — one parametrized case
   covering the busy, paused and stalled states, which all feed the same
   delay computation. Errors keep their backoff even after a waited reply
   was seen.
8. Stopping aborts an in-flight HTTP watch and suppresses late wake-ups.
   Real Pi smoke covers a parked watcher alongside main-session send/receive
   and broker restart.
9. `mix test`, all Node suites, and all three smokes pass unchanged — plain
   replies are byte-identical, so no existing assertion moves.

## Risks

- Session ownership and independent-session concurrency — criterion 1 is a
  hard gate; a two-client test does not prove same-session concurrency.
- Bandit request timeouts must exceed the 25s cap; verify and, if needed, set
  explicitly in the Bandit opts where the router is mounted.
- Peri's drop-unknown-args behavior is load-bearing for old-server
  compatibility. If Anubis ever switches to rejecting unknown tool args, the
  watcher needs a capability probe back — note it here so the failure is
  recognized, not rediscovered.
