# Plan: message threading (`reply_to`)

## Problem

Messages carry server-assigned ids (`message-N`) but replies are free-floating
prose: with two tasks in flight, a worker's "Done" cannot be correlated with
the task it answers — not by the PM agent, not by the operator reading the
history. The structure half-exists already: every send returns `message_id`
and every received message carries `id`; nothing lets a sender point at one.

## Simplest solution

One optional field on `communicate action: "send"`: `reply_to`, the id of the
message being answered. The hub stores it on the message map it already
builds, which makes it appear everywhere that map travels — recipients'
inbox copies, `snapshot` history, and the SQLite archive — with no further
plumbing.

- **Validation is shape-only** (`valid_id?/1`, the existing
  `~r/\A[a-zA-Z0-9_.-]{1,64}\z/`); violations are `invalid_request`.
  Existence is deliberately not checked: the in-memory window is bounded by
  `history_limit`, so an existence check would make validity depend on
  eviction timing, and a reply to a pruned message is still a true statement
  about causality. No `message-` prefix check either — the id shape is
  contract enough.
- The key is always present on new messages (`reply_to: nil` when not a
  reply); absent on pre-existing rows, which decode to `nil`.

### Changes, file by file

- `lib/agent_talk/hub.ex`, `"send"` branch of `communicate/3`: one new clause
  in the `with` chain (`:ok <- validate_reply_to(...)`) and
  `reply_to: Map.get(args, :reply_to)` added to the `message` map. Nothing
  else — the same map becomes the inbox copy and the history event. One
  sentence in `registration/2` instructions tells agents to set it when
  answering a specific message.
- `lib/agent_talk/tools/communicate.ex`: `field(:reply_to, :string, ...)` and
  one moduledoc sentence.
- `lib/agent_talk/history.ex`: add `:reply_to` to `@fields`. Events are a
  JSON blob (`event_json`), so **no schema migration**; `user_version` stays
  1. The strict binary-validation list in `decode_rows/1`
  (`~w(id ring_id ...)`) must NOT grow, or pre-threading archives would fail
  to load. `markdown/2` renders one `Reply-To: message-N` line when present.
- `lib/agent_talk/web/operator_live.ex`: display-only "↩ message-N" text tag
  on reply messages. No anchors, no regrouping of the flat timeline.
- Clients (`integrations/*`, `cli/`): zero changes. The watcher never sends;
  `mcp.mjs` passes tool args through; agents adopt the field from the tool
  description.

## Deliberately cut

- Existence/ring-membership validation of the parent id.
- Threaded or grouped rendering in the LiveView; anchor links to parents.
- Any client or onboarding-prompt changes.

## Acceptance criteria

1. A send with `reply_to` delivers the field in each recipient's `receive`
   payload and in `snapshot` history (`hub_test.exs`, plus one end-to-end
   `structuredContent` assertion in `mcp_test.exs`).
2. A send without `reply_to` yields `reply_to: nil` and is otherwise
   unchanged; no existing test needs edits beyond tests that assert exact key
   sets.
3. `reply_to` values failing `valid_id?/1` (empty, whitespace, non-string,
   65+ chars) return `invalid_request`; a well-formed id that was evicted or
   never existed succeeds.
4. Round-trip through the archive: record a reply, `recent/2` returns it with
   `reply_to`; a pre-threading row (event_json without the key) still decodes,
   as `nil` (`history_test.exs`).
5. `markdown/2` output contains `Reply-To:` for replies and omits it
   otherwise.
6. The LiveView renders the tag for replies and is unchanged for plain
   messages.
7. `mix test`, all Node suites, and all three smokes pass.

## Risks

Only one trap: adding `reply_to` to `decode_rows/1`'s required-binary list
would break old archives — criterion 4 exists to catch exactly that.
