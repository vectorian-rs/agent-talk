# Plan: durable inboxes across hub restarts

## Problem

Membership survives a restart (`MembershipStore`), and every message and its
collection status survive in the SQLite archive (`AgentTalk.History`,
`collected_json`), but queued inboxes do not: `restore/3` in
`lib/agent_talk/hub.ex` resets every node to `inbox: :queue.new()`. A hub
restart therefore silently drops mail that was sent and acknowledged
(`delivered_to`) but not yet collected — the one loss mode agents cannot
detect, because their lease and ids remain valid.

## Key insight: no new storage

A pending message is fully derivable from state we already persist:

> pending for node N = messages where `N ∈ to` and `N ∉ collected_json`,
> and N's membership survived.

Expiry is the only path that discards queued mail, and expiry also removes the
node from the membership file — so an expired node is never restored, and its
discarded messages are never resurrected. For every node that *is* restored,
"uncollected" and "queued" are the same set. Rebuilding inboxes from the
archive is therefore consistent with today's semantics, minus the restart data
loss.

`init/1` already loads this exact data: `History.recent(db, history_limit)`
populates `state.messages` with events carrying `to` and `received_by`. The
rebuild needs no new SQL and no schema change (`user_version` stays 1).

## Hub changes (`lib/agent_talk/hub.ex`)

In `restore/3` (or just after it in `init/1`, once `state.messages` is
loaded — note `restore/3` currently runs *before* messages are merged in, so
the rebuild belongs in `init/1` after the `Map.merge` that sets `messages`):

- For each restored node, rebuild
  `inbox = state.messages |> Enum.filter(&(node_id in &1.to and node_id not in &1.received_by)) |> Enum.reverse() |> Enum.map(&Map.take(&1, [:id, :from, :ring_id, :message, :sent_at])) |> :queue.from_list()`.
  `state.messages` is newest-first; the reverse restores FIFO order. The
  `Map.take` reconstructs exactly the inbox-copy shape built in the `"send"`
  branch of `communicate/3`.
- Clamp to `max_inbox` (keep the oldest, matching queue order) so a restart
  cannot produce an inbox the live path would have refused.
- Then run `expire_nodes/2` as today — expiry still wins over restoration.

No changes to the send/receive paths, persistence pipeline, or error codes.

## Semantics and bounds

- **Retention window**: the rebuild sees only the `history_limit` most recent
  events (default in config). A message older than the window that was never
  collected is not restored. This is the same bound the operator view already
  lives with; document it in the README's persistence section rather than
  adding a second query path.
- **History disabled** (`history_file: nil`): nothing to rebuild; inboxes stay
  ephemeral, exactly today's behavior. The `history_persistent` flag already
  surfaced in `snapshot` tells the operator which mode they are in.
- **Collection durability**: `History.record` for `receive` updates
  `collected_json` inside a transaction with `synchronous=FULL`, and a failed
  record already fails the receive (the `:storage` error path in
  `handle_call`), so a crash cannot lose a collection mark that the client saw
  succeed — no double-delivery after restart. The reverse (marked collected,
  reply lost in transit) means a dropped message the agent never saw; that is
  today's behavior for any lost HTTP reply and stays out of scope.
- **At-least-once framing**: after this change the hub's story is "a message
  acknowledged with `delivered_to` is either collected, or discarded by the
  recipient's expiry — never by a hub restart." Put that sentence in the
  README and in the `registration/2` instructions text, replacing the current
  "recipient expiry can discard them before collection" caveat's silent
  restart case.

## Tests

- `test/agent_talk/persistence_test.exs`: send → stop hub → start hub with the
  same files → recipient's `receive` returns the message; `list_nodes` inbox
  metadata shows it pending before collection. Update any existing assertion
  that encodes the old "restart clears inboxes" behavior.
- Collected-before-restart message is *not* re-delivered after restart.
- Expired node's mail is not resurrected: send to a node, let it expire, stop,
  start, rejoin with the ring token — new node id, empty inbox.
- `max_inbox` clamp on rebuild (small `max_inbox` in opts).
- History-disabled config keeps today's behavior.
- `examples/pi_smoke.exs` ("automatic replies after server restart") should
  pass unchanged — if it starts failing it is signal, not noise: it means the
  smoke depended on restart-drops.

## Risks

- **Hidden test/consumer assumptions** that restart implies empty inboxes
  (persistence tests, possibly the Pi smoke). The work is mostly auditing
  those expectations; the mechanism itself is ~20 lines.
- **`received_by` vs `collected_json` fidelity**: `decode_rows/1` derives
  `received_by` from `collected_json`, which is the durable truth — the
  in-memory-only `received_by` updates on the live path are a superset. No gap
  identified, but the persistence test matrix above is designed to catch one.
- **Interaction with the long-poll plan** (`docs/plan-long-poll.md`): none —
  waiters are in-memory and die with the hub; restored pending mail satisfies
  the first `list_nodes` after restart immediately.

## Follow-up this unlocks

Per-message delivery states (`queued → collected / expired`) in the operator
LiveView become cheap once the archive is the source of truth for pending
mail; expiry would then write a tombstone into `collected_json` (e.g.
`"expired:<timestamp>"`) instead of discarding silently. Out of scope here.
