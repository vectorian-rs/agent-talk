# Plan: read receipts (delivery visibility for the sender)

Status: draft (plan only). Least-complexity design for review before implementing.

## Problem

A sender learns its recipients at send time (`communicate send` returns
`delivered_to`), but has no way to ask later *"has the worker actually picked
this up?"*. The hub already knows the answer — every event carries
`received_by` (appended when a recipient runs `receive`, hub.ex:557), and the
operator UI already renders it as "Collected 1/2". The information exists; it is
simply never exposed back to the agent that sent the message. A PM assigning
work has to guess, or ask over a side channel.

## Simplest solution

One new read-only `communicate` action: `status`. It returns the caller's own
recently-sent messages, each with who has received it and who is still pending.
No new tool, no new storage, no new tracking — it derives entirely from the
in-memory history window (`state.messages`) the operator view already uses.

- `communicate.ex`: the `action` enum gains `"status"` (today `["send",
  "receive"]`); no other field becomes required. The moduledoc gains one line.
- `hub.ex`: a new `communicate(%{action: "status"}, state, node)` clause filters
  `state.messages` to events where `from == node.node_id`, and returns
  `{:ok, %{sent: [...]}}` where each entry is
  `%{id, to, received_by, pending, sent_at, reply_to}` and
  `pending = to -- received_by`. Read-only: it renews the caller's lease like
  any authenticated call but never mutates mail or history.
- Scope: `from == node.node_id` already restricts results to the caller's own
  sends (a node only ever sends within its own ring), so no extra ring check is
  needed. Tokens are never included.
- Bound: results cover only messages still in the in-memory history window
  (`history_limit`, the same window the operator shows). Older sends age out.
  This is documented, not a silent truncation — the same bound already governs
  the dashboard.

Pull-only by design: the caller asks when it wants to know. No push, no waking
the sender on a read.

## Acceptance criteria

1. After a send to two recipients, `status` lists that message with both
   recipients in `pending` and an empty `received_by`.
2. After one recipient runs `receive`, `status` moves that recipient from
   `pending` into `received_by`; the other stays pending.
3. `status` returns only the caller's own sent messages — another node's sends
   never appear, even in the same ring.
4. A message aged out of the history window is absent from `status` (documented
   bound), not an error.
5. `status` renews the lease and leaves inboxes and history unchanged; `send`
   and `receive` behave exactly as before.
6. End to end over MCP, `structuredContent.sent` carries the per-recipient
   received/pending breakdown; an unauthenticated or wrong-token call is
   rejected like any other `communicate`.

## Deliberately cut

- **Archive-backed status** beyond the in-memory window. The archive's
  `collected_json` could answer for older messages, but querying it is more
  machinery than the MVP needs; the window matches operator parity.
- **Read timestamps.** `received_by` reports presence (who), not when. The
  archive already stores collection times if per-read timing is wanted later.
- **Push / notify-on-read.** No long-poll for a read event and no waking the
  sender; `status` is strictly pull. Extending the existing `wait_seconds`
  parking to "wait until read" is a possible future, not this.
- **A separate tool.** `status` rides the existing `communicate` tool rather
  than adding a fourth MCP tool, keeping the surface at three.
