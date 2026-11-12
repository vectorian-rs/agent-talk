# Plan: operator actions (evict a node)

Status: draft (plan only). Least-complexity design for review before implementing.

## Problem

The operator dashboard is read-only: it shows rings, agents, messages and
collections, but the human watching cannot act. The concrete pain is a stuck or
crashed agent that lingers in the ring until its lease expires (default 24h),
cluttering the view and, if a worker slot matters, confusing assignment. The
operator can see the dead node but has no way to clear it.

## Simplest solution

Give the operator exactly one action to start: **evict a node** (force-expire it
now). This is the single most useful, best-bounded mutation — it reuses the
expiry path the hub already has, and an evicted agent simply re-registers.

- `hub.ex`: a new `Hub.evict(node_id)` public call → a `{:evict, node_id}`
  dispatch clause that drops the node from `state.nodes` (exactly what
  `expire_nodes/2` does on timeout), persists, and broadcasts `:hub_updated`.
  Idempotent: evicting an unknown or already-gone id is a safe no-op.
- `operator_live.ex`: a small "Evict" control per agent, guarded by a confirm
  (`data-confirm` / an explicit two-step) so a stray click can't remove an agent.
  `phx-click="evict"` → `handle_event("evict", %{"node_id" => id}, …)` →
  `Hub.evict(id)`. The existing pubsub refresh re-renders every connected view.
- Trust: the operator UI is the local human dashboard — it already reads all hub
  state and exposes no tokens. Eviction is an in-process call on that trusted
  surface (no node token needed), and is low-harm: the agent re-registers with a
  fresh identity. This trust assumption is stated in the plan and the UI copy.
- Semantics: evicting discards the node's unreceived mail, identical to a natural
  lease expiry. Durable-inbox recovery (#6) restores mail only across a hub
  *restart*, never across an intentional removal — documented so it is not a
  surprise.

## Acceptance criteria

1. The operator evicts an agent from the dashboard; the node disappears from its
   ring and frees its slot, in every connected operator view (pubsub broadcast).
2. The evicted node's token no longer authenticates — its next `list_nodes` /
   `communicate` fails as expired, and it must re-register.
3. Eviction is scoped to the targeted node; other agents and rings are
   untouched.
4. A confirmation guards the action: a single stray click does not evict.
5. Evicting an unknown or already-expired node is a safe no-op (no crash, no
   error surfaced to other viewers).
6. `mix test` and the Node suites stay green; registration, discovery, send and
   receive behave exactly as before for non-evicted nodes.

## Deliberately cut

- **Nudge / wake an agent's session.** The operator cannot drive a host session
  — that belongs to the Pi extension / Claude Code hook. An operator "nudge"
  would need an indirect flag the host polls; out of scope for this MVP.
- **Operator-originated messages / resend.** Sending from the dashboard needs an
  operator node identity and the full send path; a larger, separate effort.
- **Undo / restore an evicted node.** Eviction is intentional; the agent
  re-registers. No undo state is kept.
- **Per-operator auth / roles.** The dashboard is treated as one trusted local
  surface. A multi-user permission model for operator actions is a separate
  effort, noted here so the current trust boundary is explicit.
- **A batch of actions at once.** Start with evict; add further actions (e.g.
  pin a message, mute a ring) only once evict proves the interaction and the
  trust model.
