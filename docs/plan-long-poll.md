# Plan: long-poll inbox watching (`wait_seconds`)

## Problem

Delivery latency is bounded by the watcher's polling interval. The polling
integration calls `list_nodes` every 10 seconds (`integrations/polling/watcher.mjs`,
`intervalMs = 10_000`) to read inbox metadata, and every empty poll is a wasted
round trip. Agents learn about new mail up to one interval late, and shortening
the interval just trades latency for load.

The hub already serializes everything through one GenServer
(`lib/agent_talk/hub.ex`), so it knows the instant a message is enqueued. A
caller should be able to park on the hub until that instant.

## Protocol change

`list_nodes` gains one optional field:

- `wait_seconds` (number): if the caller's inbox is empty, hold the request
  until a message arrives for the caller, the caller expires, or the wait
  elapses — then return the normal `list_nodes` payload reflecting state at
  reply time. A non-empty inbox returns immediately, as today.

Semantics and limits:

- Effective wait is `min(wait_seconds, 25, ttl_ms / 2000)` seconds. The 25s cap
  stays under common 30s proxy timeouts and the client's HTTP timeout; the
  `ttl/2` clamp keeps park duration well inside the lease so a parked, healthy
  node never expires mid-wait (parking refreshes `seen_at` on entry and again
  at reply).
- Validation: reject non-numeric or negative values with
  `{:error, :invalid_request, ...}`, consistent with the hub's existing
  validators. Values above the cap are clamped, not rejected, so clients don't
  need to know the server's TTL.
- Capability signal: the `list_nodes` reply gains `waited_seconds` (the
  effective wait granted, `0` when the reply was immediate). Its presence tells
  clients the server supports long-polling; old servers that ignore unknown
  fields simply omit it. This is what prevents a new watcher against an old
  server from degrading into a tight loop.
- `communicate action: "receive"` gains the same `wait_seconds` field in a
  second phase, reusing the identical parking mechanism (see Phase D). The
  watcher never drains mail, so `list_nodes` is the primary consumer.

## Hub design

New state: `waiters :: %{node_id => %{from: GenServer.from(), ref: reference(), kind: :list | :receive, args: map()}}` —
at most one waiter per node.

- `dispatch({:list, args}, ...)`: when `wait_seconds` is present, the inbox is
  empty, and validation passes, return a new `{:park, node_id, wait_ms, reply_args}`
  shape instead of `{reply, state}`. `handle_call` runs the normal
  `persist/3` → `History.record` → `notify_if_changed` pipeline on the updated
  state (the park still renews the lease via `authenticate/3` and applies label
  updates), stores the waiter with `Process.send_after(self(), {:waiter_timeout, ref}, wait_ms)`,
  and returns `{:noreply, persisted}`.
- If the node already has a waiter (client retried), reply to the old waiter
  immediately with the current empty payload and replace it — no leaked `from`s.
- Wake on delivery: at the end of the `"send"` branch of `communicate/3`, after
  inboxes are updated, reply to every recipient's waiter with a freshly built
  payload (`list_nodes` metadata, or drained messages for `:receive` waiters),
  cancel timers, and drop them from `waiters`. A `:receive` waiter's inbox
  drain is a state change, but it happens inside the sender's `handle_call`, so
  it flows through the sender's persist/record pipeline for free.
- `{:waiter_timeout, ref}` in `handle_info`: reply with the current (empty)
  payload, refresh the node's `seen_at`, persist via the existing
  presence-deferral path, and drop the waiter.
- `expire_nodes/2`: when it removes a node that has a waiter, reply
  `{:error, :expired, @missing_node_error}` and drop the waiter. This covers
  test configs with very short TTLs.
- `terminate/2`: no special handling; a dying hub crashes parked callers the
  same way it crashes active ones today.

Reply-time payloads are pure reads (inbox length + head id + ring members), so
no `History.record` is needed when a parked `list_nodes` wakes.

## Caller plumbing

- `AgentTalk.Hub.list_nodes/2` and `communicate/2` (hub.ex:20-21) use the
  default 5s `GenServer.call` timeout. When `args` carry `wait_seconds`, pass
  `wait_ms + 5_000` as the call timeout.
- `lib/agent_talk/tools/list_nodes.ex`: add the schema field
  (`field(:wait_seconds, :number, description: ...)`) and document the
  semantics in the moduledoc, which is agent-facing.
- `integrations/polling/mcp.mjs`: `request/4` hard-codes
  `AbortSignal.timeout(15_000)`. Make the timeout a per-call parameter;
  `call()` passes `wait_seconds * 1000 + 5_000` when the args include a wait.
- `integrations/polling/watcher.mjs`: when the previous reply carried
  `waited_seconds`, poll again immediately with
  `wait_seconds = min(25, member.expires_in_seconds / 3)` instead of sleeping
  `pollIntervalMs`. Keep the existing failure backoff, membership-wait 250ms
  loop, and paused behavior untouched. Without `waited_seconds` in the reply
  (old server), behavior is exactly today's interval polling.

## Verification spike (do first)

The design assumes a parked tool call does not serialize other MCP traffic.
Each streamable-HTTP POST is its own Bandit request process, and the watcher
and the agent use separate MCP sessions, but Anubis's session handling must be
confirmed: write a throwaway test where one client parks on `list_nodes` while
a second client (and then the *same* client) sends a message. If Anubis
serializes per-session requests, the receive-phase design (same session parks
and sends) is off the table and only the watcher path ships.

## Phases

- **A — spike**: concurrency verification above; 1 test, discarded or kept as
  a regression test.
- **B — hub parking**: waiters map, park/wake/timeout/expiry paths,
  `waited_seconds` in the reply, call-timeout plumbing, schema field.
- **C — watcher adoption**: `mcp.mjs` timeout parameter, watcher long-poll
  pacing with old-server fallback.
- **D — receive wait** (optional, follow-up PR): same field on
  `communicate action: "receive"` for agents that block between tasks, reusing
  the `:receive` waiter kind.

## Tests

- `test/agent_talk/hub_test.exs`: park then send delivers immediately with the
  message visible in inbox metadata; timeout returns an empty payload after
  `wait_ms` (use small real waits, 50–100ms — timers are real even though the
  clock is injected); expiry during park returns the `expired` error code;
  re-park replaces the previous waiter; clamping; `invalid_request` on bad
  values.
- `test/agent_talk/mcp_test.exs`: end-to-end over HTTP — client A parks,
  client B sends, A's reply arrives in well under the wait; asserts
  `waited_seconds` is present.
- `integrations/polling/watcher.test.mjs`: with injected timers, a reply
  carrying `waited_seconds` triggers an immediate re-poll; a reply without it
  keeps interval pacing; failure backoff still applies after a long-poll error.
- `examples/lease_smoke.exs`: one assertion that a parked `list_nodes` wakes in
  under the wait when a message is sent.

## Risks

- Anubis request serialization (covered by the spike; gates Phase D).
- Bandit's default request timeouts must exceed the 25s cap — verify, and set
  explicitly in `AgentTalk.Router`'s Bandit opts if needed.
- Clients behind aggressive proxies: the 25s cap plus the `waited_seconds`
  fallback means a proxy-killed park surfaces as a transport error and the
  watcher's existing backoff takes over.
