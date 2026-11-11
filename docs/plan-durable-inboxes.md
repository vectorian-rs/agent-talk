# Plan: durable inboxes across hub restarts

## Problem

Membership survives a restart (`MembershipStore`) and every message plus its
collection status survives in the SQLite archive (`collected_json`), but
queued inboxes do not: `restore/3` in `lib/agent_talk/hub.ex` resets every
node to `inbox: :queue.new()`. A restart silently drops mail that was
acknowledged with `delivered_to` but not yet collected — the one loss mode
agents cannot detect, because their lease and ids remain valid.

## Simplest solution: derive, don't store

Implement this plan before reply references (#5); long polling (#4) remains
deferred. Recovery reuses the existing SQLite archive, independently of the
operator's last-50 live window.

A pending message is fully derivable from state already persisted:

> pending for node N = messages where `N ∈ to` and N has not collected, and
> N's membership survived.

Membership restore already removes expired nodes, so only surviving node IDs
participate. `History.recent/2` is insufficient: unrelated traffic can evict
an unread assignment from the live window while its archive row survives.
Add one pending-message query over the existing `messages` table. No new
table, schema migration (`user_version` stays 1), or delivery protocol is
needed.

### Changes

- `History.pending(db, live_node_ids)` returns archived events in ascending
  `sequence` order where at least one live recipient appears in `to` but not
  in `collected_json`. Use a parameterized query across the full archive,
  with no `history_limit` or day filter. Reuse `decode_rows/1`; filter in SQL
  so collected and unrelated history is not all loaded into memory.
- In `Hub.init/1`, after `restore/3` has removed expired memberships, load
  pending events for the surviving IDs. Enqueue each event for its live,
  uncollected recipients in query order. A query failure stops startup; it
  must not silently produce empty inboxes.
- Use one `@message_fields` allowlist and an `inbox_message(event)` helper in
  the hub for both live sends and recovered inbox copies. UI/archive-only
  metadata stays out of inbox payloads. Plan #5 adds `reply_to` to this same
  definition and verifies it survives recovery.
- Keep `History.recent/2` solely for restoring the bounded operator window.
  Recovery must not insert older pending events into that window.
- Restore every pending delivery. If `max_inbox` was lowered below a saved
  backlog, retain that backlog; existing send-capacity checks reject new
  mail until it drains. Do not clamp or discard previously accepted mail.

Update the README persistence section and registration/tool instructions:
queued, uncollected mail survives a hub restart when the archive is enabled
and the recipient's membership survives. Expiry still discards that node's
mail; a rejoin receives a new ID.

### Delivery boundary

- **History disabled** (`history_file: nil`): nothing to rebuild; inboxes stay
  ephemeral, exactly today. The existing `history_persistent` snapshot flag
  already tells the operator which mode they run in.
- **Collection is not client acknowledgment**: receive commits
  `collected_json` before its HTTP response. If that response is lost, the
  message remains collected and recovery does not replay it. This provides
  restart recovery for queued mail, not at-least-once delivery or proof of
  processing. Explicit acknowledgments/retries remain out of scope.

## Deliberately cut

- A dedicated pending-messages table or any new persistence.
- Expiry tombstones in `collected_json` and per-message delivery states in
  the LiveView — this plan makes them cheap later, but they are a separate
  feature.
- Any client, protocol, or error-code change.

## Acceptance criteria

All in `persistence_test.exs` unless noted:

1. Send → stop hub → start hub on the same files → the recipient's first
   `receive` returns the message and its next receive is empty. Before
   collection, inbox metadata shows the count and `next_message_id`.
2. A message collected before the restart is not redelivered after it.
3. Expired mail is not resurrected: send to a node, let it expire, restart,
   rejoin with the ring token — new node id, empty inbox.
4. FIFO order survives a restart (send two, restart, receive returns both in
   order).
5. With `history_file: nil`, restart behavior is exactly today's (empty
   inboxes).
6. Send one unread assignment to worker A, then at least 50 messages to
   worker B (also cover traffic in another ring). With `history_limit: 50`,
   A's assignment survives restart even though it is outside the live window.
   Also restore more than 50 pending messages in FIFO order.
7. Lower `max_inbox` below the saved pending count: restore the full backlog,
   reject new sends as full, then accept sends after collection frees space.
8. Fan-out collection is per recipient: after A collects and B does not,
   restart restores the message only for B.
9. A failed pending query stops startup. A receive whose response is ignored
   still commits collection; restart does not replay it.
10. `examples/pi_smoke.exs` ("automatic replies after server restart") passes
   unchanged — if it fails, it depended on restart-drops and that is signal.
11. `mix test`, all Node suites, and all three smokes pass; existing
   assertions change only where they encoded restart-clears-inboxes.

## Risks

- Hidden assumptions that restart implies empty inboxes (persistence tests,
  possibly the Pi smoke) — most of the real work is this audit; the mechanism
  is small.
- Pending-query cost grows with archive size. Select matching pending rows
  in SQLite; the live-window limit must never become a recovery cutoff.
- Plan #5 must extend the shared inbox field definition and test recovery of
  replies, including a parent outside the live window.
- Interaction with `docs/plan-long-poll.md`: none — waiters are in-memory and
  die with the hub; restored pending mail satisfies the first post-restart
  `list_nodes` immediately.
