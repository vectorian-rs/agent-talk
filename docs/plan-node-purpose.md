# Plan: node purpose line (capability discovery)

Status: implemented on top of main. A minimal "agent card": one optional
free-text line per node, set at register and shown in `list_nodes`, so peers
route by what a node does instead of guessing from role and name.

## Problem

Today a caller picks a recipient by `role` or by reading a `name` label. Neither
says what a node actually does. Larger protocols (A2A agent cards) solve this
with rich capability documents and discovery endpoints; the least-complexity
form of the same idea is one human-readable sentence the sender can skim.

## Simplest solution

`purpose` is a third display label alongside `project` and `name`. It reuses the
existing label machinery end to end:

- `register_node` and `list_nodes` accept an optional `purpose` (1..128
  characters, no control characters — the same rule as the other labels, via a
  shared `@label_fields`).
- It is set at register, updatable on `list_nodes` like the other labels, and
  returned on every node in `list_nodes` and the operator snapshot.
- It persists across restarts (added to the membership store's node fields and
  its validation), so a recovered node keeps advertising.
- The operator view shows it under a node, only when set.

No new tool, no new error code, no schema migration (membership is JSON), and
plain behavior for nodes that never set one.

## Acceptance criteria

1. A node registered with `purpose` returns it, and peers see it in `list_nodes`;
   a node without one lists `purpose: null`.
2. `purpose` can be updated through `list_nodes` like `name`/`project`, and a
   non-text or control-character value is `invalid_labels`.
3. `purpose` survives a hub restart (membership round-trip).
4. End to end over MCP, a worker's `purpose` reaches the PM's `list_nodes`.
5. The operator UI shows a node's `purpose` only when set.
6. `mix test` and all Node suites stay green; no existing assertion moves except
   to add `purpose`.

## Deliberately cut

- Structured capabilities, tags, or skill lists — one line is enough to route;
  richer structure is an A2A agent card, a separate effort.
- Searching/filtering `list_nodes` by `purpose` — the sender reads the lines and
  picks; a server-side query is premature.
- CLI provisioning of `purpose` — it is domain-specific per agent, so the CLI
  leaves it unset and agents set it themselves through the tool.
