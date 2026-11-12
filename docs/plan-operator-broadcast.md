# Plan: operator broadcast (message a ring from the dashboard)

Status: implemented on top of main. The operator dashboard can broadcast a
message to every member of the selected ring via `Hub.broadcast/2`, reusing the
agent send path. This is the "operator-originated messages" item deliberately
cut from the evict plan (`plan-operator-actions.md`), now its own effort.

## Problem

The operator dashboard can watch traffic and now evict a stuck node, but it
still cannot *say* anything. When the human watching needs to reach the agents —
"pause, the spec changed", "wrap up and report" — they have no channel. Their
only options are out of band (Slack, a terminal) and invisible to the ring's own
message log, so the nudge and the agents' reactions are never correlated in one
place.

## Simplest solution

Give the operator one action: **broadcast a message to the selected ring**. It
reuses the agent send path wholesale — the same `event` shape, `deliver/3` fan
-out, capacity check, history window and pubsub refresh — with a synthetic
`"operator"` sender in place of a ring-member `from`.

- `hub.ex`: a new `Hub.broadcast(ring_id, message)` public call → a
  `{:broadcast, ring_id, message}` dispatch clause. It resolves the ring's
  current members (`ring_nodes/2`), validates the message and capacity exactly
  as a send does, builds an `event` whose `from`/`from_role`/`from_name` are the
  reserved operator identity (`"operator"` / `"operator"` / `"Operator"`),
  delivers to every member, appends to history, and returns
  `{:ok, %{message_id, delivered_to}}`. `handle_call`'s existing persist +
  archive + broadcast + wake-waiters wrapper applies unchanged, so a parked
  long-poll watcher wakes on the new mail and every operator view refreshes.
- `operator_live.ex`: a small compose box in the agents panel, scoped to the
  selected ring and shown only when that ring has members. `phx-submit="broadcast"`
  → `handle_event("broadcast", %{"message" => msg}, …)` → `Hub.broadcast(ring, msg)`.
  A `data-confirm` naming the recipient count guards an accidental send; a
  storage or capacity error is surfaced in the existing error banner, never
  crashing the view. The textarea is tracked in an assign so a concurrent
  refresh cannot wipe a half-typed message, and clears on a successful send.
- Trust: identical to evict — the dashboard is the trusted local surface, reads
  all hub state, exposes no tokens, and so broadcasts need no node token. The
  synthetic sender cannot authenticate anything; `"operator"` is not a
  registered node and owns no token.
- Display: the message log already renders a multi-recipient message as
  "Broadcast · N recipients" and labels the sender from `from_name`, so an
  operator broadcast shows as from "Operator" with no new rendering code.
- One-way: an operator broadcast is an announcement. The `operator` sender has
  no inbox, so agents must not reply to it — a response belongs to the agent's
  PM, over the normal send path. This keeps the send path free of a special
  "reply to the operator" case; see "Deliberately cut".

## Acceptance criteria

1. The operator broadcasts from the dashboard; every current member of the
   selected ring receives one copy in its inbox, and the message appears in the
   log attributed to "Operator", in every connected operator view.
2. The broadcast is scoped to the selected ring; nodes in other rings receive
   nothing.
3. A parked long-poll watcher on a recipient wakes immediately on the broadcast
   (it is ordinary mail through the shared delivery path).
4. An empty or whitespace-only message is rejected; an empty ring (no members)
   is rejected with a clear message, not a silent no-op that looks sent.
5. If a recipient inbox is full the broadcast is refused atomically (no partial
   delivery) and the operator sees the error, matching agent-send semantics.
6. A confirmation guards the action and names how many agents will receive it; a
   single stray click does not broadcast.
7. `mix test` and the Node suites stay green; registration, discovery, agent
   send and receive behave exactly as before.

## Deliberately cut

- **Role / subset targeting.** Start with the whole ring, mirroring how evict
  started with one action. `to_role`-style filtering (broadcast only to workers)
  is a natural follow-up once the whole-ring send proves the interaction.
- **Reply threading from the operator.** The operator message sets `reply_to:
  nil`; letting the operator answer a specific message in the log is a separate,
  larger UI effort.
- **Delivery receipts view for the operator's own sends.** The agent `status`
  action reports a node's sends; the operator already sees per-message delivery
  state live in the log, so no operator-side `status` equivalent is added.
- **Scheduling / recurring broadcasts.** One message, sent now. Anything timed
  belongs to a scheduler, not the hub.
- **Cross-ring / all-rings broadcast.** One ring at a time, the ring already
  selected in the view. A fan-out to every ring at once is a bigger blast radius
  that should be its own decision.
