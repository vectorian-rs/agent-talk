# Plan: durable inboxes across hub restarts

## Problem

Membership survives a restart (`MembershipStore`) and every message plus its
collection status survives in the SQLite archive (`collected_json`), but
queued inboxes do not: `restore/3` in `lib/agent_talk/hub.ex` resets every
node to `inbox: :queue.new()`. A restart silently drops mail that was
acknowledged with `delivered_to` but not yet collected — the one loss mode
agents cannot detect, because their lease and ids remain valid.

## Simplest solution: derive, don't store

A pending message is fully derivable from state already persisted:

> pending for node N = messages where `N ∈ to` and N has not collected, and
> N's membership survived.

Expiry is the only path that discards queued mail, and expiry also removes
the node from the membership file — so an expired node is never restored and
its discarded mail is never resurrected. For every node that *is* restored,
"uncollected" equals "queued". And `init/1` already loads the needed data:
`History.recent/2` populates `state.messages` with events carrying `to` and
`received_by`. **No new storage, no new SQL, no schema change
(`user_version` stays 1), no change to live send/receive paths.**

### The change (~20 lines)

In `init/1`, after `messages` is merged into state (note: `restore/3` runs
before that merge, so the rebuild goes after it) and before `expire_nodes/2`
applies:

- For each restored node:
  `inbox = state.messages |> Enum.filter(&(node_id in &1.to and node_id not in &1.received_by)) |> Enum.reverse() |> Enum.map(&Map.take(&1, [:id, :from, :ring_id, :message, :sent_at])) |> :queue.from_list()`.
  `state.messages` is newest-first; the reverse restores FIFO order, and the
  `Map.take` reconstructs exactly the inbox-copy shape the `"send"` branch
  builds.
- Clamp to `max_inbox`, keeping the oldest (queue order), so a restart cannot
  produce an inbox the live path would have refused.
- Expiry still runs afterward and still wins.

Documentation: replace the restart caveat implied by "recipient expiry can
discard them before collection" with the new story — *a message acknowledged
with `delivered_to` is either collected or discarded by the recipient's
expiry, never by a hub restart* — in the README persistence section and the
`registration/2` instructions text.

### Bounds that keep it simple

- **Retention window**: the rebuild sees only the `history_limit` most recent
  events, the same bound the operator view already lives with. An uncollected
  message older than the window is not restored; documented, not engineered
  around.
- **History disabled** (`history_file: nil`): nothing to rebuild; inboxes stay
  ephemeral, exactly today. The existing `history_persistent` snapshot flag
  already tells the operator which mode they run in.
- **No double-delivery**: `History.record` for `receive` commits
  `collected_json` with `synchronous=FULL`, and a failed record already fails
  the receive (the `:storage` error path), so a crash cannot lose a collection
  mark the client saw succeed.

## Deliberately cut

- A dedicated pending-messages table or any new persistence.
- Expiry tombstones in `collected_json` and per-message delivery states in
  the LiveView — this plan makes them cheap later, but they are a separate
  feature.
- Any client, protocol, or error-code change (this is invisible to clients
  except that mail stops vanishing).

## Acceptance criteria

All in `persistence_test.exs` unless noted:

1. Send → stop hub → start hub on the same files → the recipient's `receive`
   returns the message exactly once, and `list_nodes` inbox metadata shows it
   pending (correct count and `next_message_id`) before collection.
2. A message collected before the restart is not redelivered after it.
3. Expired mail is not resurrected: send to a node, let it expire, restart,
   rejoin with the ring token — new node id, empty inbox.
4. FIFO order survives a restart (send two, restart, receive returns both in
   order).
5. With `history_file: nil`, restart behavior is exactly today's (empty
   inboxes).
6. A small `max_inbox` in opts clamps the rebuild to the oldest messages.
7. `examples/pi_smoke.exs` ("automatic replies after server restart") passes
   unchanged — if it fails, it depended on restart-drops and that is signal.
8. `mix test`, all Node suites, and all three smokes pass; existing
   assertions change only where they encoded restart-clears-inboxes.

## Risks

- Hidden assumptions that restart implies empty inboxes (persistence tests,
  possibly the Pi smoke) — most of the real work is this audit; the mechanism
  is small.
- `received_by` fidelity: `decode_rows/1` derives it from `collected_json`,
  the durable truth; the live path only adds to it. No gap identified;
  criteria 1–2 are designed to catch one.
- Interaction with `docs/plan-long-poll.md`: none — waiters are in-memory and
  die with the hub; restored pending mail satisfies the first post-restart
  `list_nodes` immediately.
