# Plan: long-poll inbox watching (`wait_seconds`)

Status: deferred. Implement inbox recovery (#6), then reply references (#5).
Keep the current 10-second watcher until lower notification latency is a
requirement; this plan adds timer and concurrency handling without changing
which messages agents can receive.

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
inboxes return immediately, as today. Every `list_nodes` reply gains
`waited_seconds` (effective wait granted, `0` when immediate) — its presence
is how clients detect support, so a new watcher against an old server falls
back to interval polling instead of tight-looping.

Effective wait is `min(wait_seconds, 25, ttl_ms / 2000)` seconds: under
common 30s proxy timeouts and well inside the lease, so a parked healthy node
never expires mid-wait. Values above the cap are clamped; non-numeric or
negative values are `invalid_request`.

### Hub mechanism (the whole of it)

- State gains `waiters :: %{node_id => {from, timer_ref, args, wait_ms}}` —
  at most one per node. Use
  `:erlang.start_timer(wait_ms, self(), {:waiter_timeout, node_id})`; its
  returned timer reference identifies that park. A second park releases the
  first and cancels its timer before replacing it.
- `dispatch({:list, args}, ...)` returns a new `{:park, node_id, wait_ms}`
  shape when the wait applies. `handle_call` runs the normal
  `persist → record → notify` pipeline (the park already renewed the lease and
  applied labels via `authenticate/3`), starts the timer, stores the waiter
  and returns `{:noreply, persisted}`.
- **Waking is re-dispatch, not a parallel reply path**: to wake a waiter, run
  its stored args minus `wait_seconds` back through `dispatch({:list, ...})`
  and `GenServer.reply` with the result, setting `waited_seconds` to the
  stored `wait_ms / 1000` rather than the immediate re-dispatch's zero.
  Cancel the timer when releasing the waiter. No second payload builder is
  needed; the field reports the original grant even on an early wake.
- **One wake function, no touched send path**: `wake_ready_waiters(state)`
  runs at the end of `handle_call` and the `:sweep` branch of `handle_info`.
  For each waiter: node gone → reply `{:error, :expired, @missing_node_error}`;
  inbox non-empty → re-dispatch and reply; otherwise keep waiting. The send
  branch of `communicate/3` is not modified at all.
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
- The watcher owns a separate `McpClient` and MCP session from the main
  agent. Anubis serializes ordinary requests within a session; sharing one
  could hold the agent's send/receive behind a parked watch.
- `integrations/polling/watcher.mjs`: after detecting `waited_seconds`, the
  next checks request `wait_seconds = min(25, expires_in_seconds / 3)`.
  Schedule by outcome, not capability alone. Successful empty replies after
  a granted wait (`waited_seconds > 0`) immediately start the next long poll.
  Non-empty inboxes or immediate replies (`waited_seconds == 0`) keep the
  ordinary heartbeat interval, including busy, paused and stalled agents.
  Repeated immediate replies must not spin.
- Missing membership keeps the 250ms check; errors keep existing backoff.
  Old-server replies without `waited_seconds` keep interval polling. Existing
  stop, cancellation, wake budgeting and settled checks still apply.

## Deliberately cut

- Blocking `communicate receive` (the watcher never drains mail; agents drain
  only when woken, so a blocking receive has no consumer today).
- Waiter "kinds", per-waiter payload builders, capability negotiation beyond
  the `waited_seconds` field.

## Acceptance criteria

1. **Gate (write this test first)**: over real HTTP in `mcp_test.exs`, a
   dedicated watcher session parks with `wait_seconds: 10`. Other sessions
   still send and receive in < 2s; a send to the watched node unblocks its
   metadata check in < 2s. This tests concurrency across sessions, not within
   one. If independent sessions block, stop and redesign.
2. With no send, a parked call returns an empty payload after the effective
   wait (small real waits in `hub_test.exs`; timers are real even though the
   clock is injected) with `waited_seconds > 0`.
3. A non-empty inbox returns immediately with `waited_seconds == 0`.
4. Node expiry during a park replies with error code `expired`.
5. A second park from the same node releases the first immediately. Inject
   the old timeout after replacement: it must neither reply to nor remove
   the new waiter. A matching timeout or send releases the new waiter once;
   no waiter leaks remain.
6. A call without `wait_seconds` behaves exactly as today except for the added
   `waited_seconds: 0` field; `wait_seconds: "x"` or `-1` is
   `invalid_request`.
7. Watcher (fake timers): an empty waited reply schedules immediately;
   immediate replies and old-server replies keep interval pacing. Leave a
   message unread through repeated checks in busy, paused and stalled states:
   every check must retain a nonzero heartbeat delay and bounded wake-ups.
   Errors keep their backoff even after support was detected.
8. Stopping aborts an in-flight HTTP watch and suppresses late wake-ups;
   missing membership keeps its existing cadence. Real Pi smoke covers a
   parked watcher alongside main-session send/receive and broker restart.
9. `mix test`, all Node suites, and all three smokes pass; only tests
   asserting exact reply key sets may change.

## Risks

- Session ownership and independent-session concurrency — criterion 1 is a
  hard gate; a two-client test does not prove same-session concurrency.
- Bandit request timeouts must exceed the 25s cap; verify and, if needed, set
  explicitly in the Bandit opts where the router is mounted.
