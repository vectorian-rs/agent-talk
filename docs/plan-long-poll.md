# Plan: long-poll inbox watching (`wait_seconds`)

## Problem

Delivery latency is bounded by the watcher's polling interval
(`integrations/polling/watcher.mjs`, `intervalMs = 10_000`), and every empty
poll is a wasted round trip. The hub serializes everything through one
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

- State gains `waiters :: %{node_id => {from, timer_ref, args}}` — at most one
  per node. A second park from the same node releases the first immediately.
- `dispatch({:list, args}, ...)` returns a new `{:park, node_id, wait_ms}`
  shape when the wait applies. `handle_call` runs the normal
  `persist → record → notify` pipeline (the park already renewed the lease and
  applied labels via `authenticate/3`), stores the waiter with a
  `Process.send_after(self(), {:waiter_timeout, node_id}, wait_ms)`, and
  returns `{:noreply, persisted}`.
- **Waking is re-dispatch, not a parallel reply path**: to wake a waiter, run
  its stored args minus `wait_seconds` back through `dispatch({:list, ...})`
  and `GenServer.reply` with the result. No second payload builder exists, so
  park replies can never drift from poll replies.
- **One wake function, no touched send path**: `wake_ready_waiters(state)`
  runs at the end of `handle_call` and the `:sweep` branch of `handle_info`.
  For each waiter: node gone → reply `{:error, :expired, @missing_node_error}`;
  inbox non-empty → re-dispatch and reply; otherwise keep waiting. The send
  branch of `communicate/3` is not modified at all.
- `{:waiter_timeout, node_id}` in `handle_info`: re-dispatch (empty payload),
  reply, drop the waiter. State changes from wake-time re-dispatch are
  presence-only and flow through the existing presence-deferral persistence.

### Plumbing

- `Hub.list_nodes/2` (hub.ex:20) passes `wait_ms + 5_000` as the
  `GenServer.call` timeout when args carry `wait_seconds`; default otherwise.
- `lib/agent_talk/tools/list_nodes.ex`: add the schema field and one moduledoc
  sentence.
- `integrations/polling/mcp.mjs`: `request/4` hard-codes
  `AbortSignal.timeout(15_000)`; make the timeout a per-call option that
  `call()` forwards.
- `integrations/polling/watcher.mjs`: when the previous reply carried
  `waited_seconds`, the next poll sends
  `wait_seconds = min(25, expires_in_seconds / 3)` and reschedules with zero
  delay. Everything else — failure backoff, 250ms membership wait, paused
  state, wake logic — is untouched.

## Deliberately cut

- Blocking `communicate receive` (the watcher never drains mail; agents drain
  only when woken, so a blocking receive has no consumer today).
- Waiter "kinds", per-waiter payload builders, capability negotiation beyond
  the `waited_seconds` field.

## Acceptance criteria

1. **Gate (write this test first)**: over real HTTP in `mcp_test.exs`, client
   A parks with `wait_seconds: 10` and client B's send unblocks A in < 2s with
   the new message visible in A's inbox metadata. This also proves Anubis does
   not serialize a parked tool call with other traffic — if it does, stop and
   redesign before writing anything else.
2. With no send, a parked call returns an empty payload after the effective
   wait (small real waits in `hub_test.exs`; timers are real even though the
   clock is injected) with `waited_seconds > 0`.
3. A non-empty inbox returns immediately with `waited_seconds == 0`.
4. Node expiry during a park replies with error code `expired`.
5. A second park from the same node releases the first immediately; no waiter
   leaks (waiters map empty after each test).
6. A call without `wait_seconds` behaves exactly as today except for the added
   `waited_seconds: 0` field; `wait_seconds: "x"` or `-1` is
   `invalid_request`.
7. Watcher (fake timers): a reply with `waited_seconds` triggers an immediate
   long-polled re-poll; replies without it keep today's interval pacing;
   failure backoff still applies after a long-poll error.
8. `mix test`, all Node suites, and all three smokes pass; only tests
   asserting exact reply key sets may change.

## Risks

- Anubis request serialization — covered by criterion 1 as a hard gate.
- Bandit request timeouts must exceed the 25s cap; verify and, if needed, set
  explicitly in the Bandit opts where the router is mounted.
