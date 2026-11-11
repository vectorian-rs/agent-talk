# Plan: message threading (`reply_to`)

## Problem

Messages carry server-assigned ids (`message-N`) but replies are free-floating
prose. When two tasks are in flight, a worker's "Done" cannot be correlated
with the task it answers — not by the PM agent, and not by the operator
reading the LiveView history. The structure already half-exists: senders get
`message_id` back from every send, and recipients see `id` on every received
message. Nothing lets them point at one.

## Protocol change

`communicate action: "send"` gains one optional field:

- `reply_to` (string): the id of the message being answered.

Semantics:

- Validated by shape only: `valid_id?/1` (the existing `~r/\A[a-zA-Z0-9_.-]{1,64}\z/`),
  plus the `message-` prefix. Existence is deliberately **not** checked: the
  in-memory history window is bounded by `history_limit` and ring-scoped
  checks would make validity depend on eviction timing. A reply to a pruned
  message is still a true statement about causality, and the archive may still
  hold the parent.
- Shape violations return `{:error, :invalid_request, "reply_to must be a message id"}`.
- The field is echoed everywhere the message travels: in the inbox copy a
  recipient drains with `receive`, in the history event, and in the SQLite
  archive. Absent means "not a reply", including for every pre-existing
  message.

No change to `list_nodes`, `register_node`, or any error code.

## Hub changes (`lib/agent_talk/hub.ex`)

In the `"send"` branch of `communicate/3`:

- Extend the `with` chain: `:ok <- validate_reply_to(Map.get(args, :reply_to))`.
- Add `reply_to: Map.get(args, :reply_to)` to the `message` map built there —
  the same map becomes both the inbox copy and (merged) the history `event`,
  so one addition covers receive payloads and `state.messages`.

That is the whole hub change; `registration/2` instructions text gains one
sentence telling agents to set `reply_to` when answering a specific message.

## Tool schema (`lib/agent_talk/tools/communicate.ex`)

- `field(:reply_to, :string, description: "Message id this send answers")`.
- Moduledoc: one sentence on when to set it (answering a task, reporting a
  result) so agents reading the tool description actually use it.

## History (`lib/agent_talk/history.ex`)

- Add `:reply_to` to `@fields`. Because events are stored as a JSON blob
  (`event_json`), **no schema migration is needed** — `user_version` stays 1.
- `decode_rows/1`: old rows lack the key and decode to `reply_to: nil`;
  validation must accept `nil` or a binary (the existing `~w(...)` binary
  check list must not grow, or old archives would fail to load).
- `markdown/2`: render `Reply-To: message-N` in the entry header when present.

## Operator LiveView (`lib/agent_talk/web/operator_live.ex`)

Minimal, display-only:

- Show a small "↩ message-N" tag on reply messages, linking (anchor) to the
  parent entry when it is still in the visible window.
- No regrouping of the flat timeline in this pass. Rendering nested threads is
  a separate UI effort and the flat view with reply tags already answers
  "which task does this Done belong to". Note it as a follow-up.

## Clients

- `integrations/polling/*`: no changes — the watcher never sends, and
  `mcp.mjs` passes arbitrary tool args through.
- `cli/` and `integrations/pi/`: no changes required; agents adopt `reply_to`
  from the tool description. The Pi onboarding prompt template is unchanged.

## Tests

- `test/agent_talk/hub_test.exs`: a send with `reply_to` delivers the field to
  recipients and into `snapshot` history; a send without it has `reply_to: nil`
  nowhere serialized as a key requirement; malformed `reply_to`
  (`"x y"`, non-string, empty) returns `invalid_request`; a reply to an
  evicted/unknown id succeeds.
- `test/agent_talk/history_test.exs`: round-trip — record a reply, `recent/2`
  returns it with `reply_to`; a pre-threading row (event_json without the key)
  still decodes.
- `test/agent_talk/mcp_test.exs`: end-to-end send→receive carries `reply_to`
  through `structuredContent`.
- LiveView test (if the web layer has one; otherwise rely on render in
  `operator_live` tests added alongside): reply tag renders and plain messages
  don't regress.

## Risks

- None structural. The only trap is adding `reply_to` to the strict binary
  validation in `decode_rows/1` and breaking old archives — covered by the
  compatibility test above.

## Follow-ups (out of scope)

- Threaded rendering in the LiveView (grouping by transitive root).
- A `thread` filter on a future history/search tool.
