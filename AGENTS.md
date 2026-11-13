# AGENTS.md

Rules for AI agents working in this repository. Read this before making changes.

## Branches and PRs for everything

Never commit to `main`. Every change goes through its own branch and a pull
request: a feature, a fix, docs, a one-line tweak. No exceptions.

1. Branch off `main` with a descriptive name (`fix/…`, `plan/…`, `feature/…`).
2. Commit on that branch.
3. Push and open a PR against `main`.
4. Merge with a merge commit, never squash (`gh pr merge <n> --merge`).
5. Delete the branch after merge.

One PR per change. Keep `main` clean and releasable.

## Writing commits and PRs

Write in plain language. No marketing tone, no filler, no needless headers or
bold, no em-dashes, no AI writing tells. Say what changed and why. A reader
should not be able to tell a machine wrote it.

Attribution trailers:

- Commit messages end with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- PR descriptions end with
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

## Verify before every PR

Everything below must pass.

- Elixir: `mix test`, `mix compile --warnings-as-errors`, `mix format --check-formatted`
- Node suites: `(cd cli && node --test)`, `(cd integrations/polling && node --test)`,
  `(cd integrations/pi && node --test)`
- Smokes: `mix run --no-start examples/lease_smoke.exs` and `examples/demo.exs` are
  reliable signals. `examples/pi_smoke.exs` has a flaky broker-restart stage, so a
  failure there alone is not a regression.

## Running the server

`mix run` swallows `--config`, so pass it after the `--` separator:

```
mix run --no-halt -- --config config/dev.toml
```

Dev config serves on port 4000 and persists to `data/` (`memberships.json` and
`history.sqlite3`). A running `Hub` GenServer keeps its old code across file
edits, so restart the server to pick up code changes.

## Project shape

- `lib/agent_talk/`: Elixir core. `Hub` is one GenServer serializing ring
  membership and per-agent mailboxes. `History` is the SQLite conversation
  archive. `tools/` holds the MCP tools (`register_node`, `list_nodes`,
  `communicate`).
- `lib/agent_talk/web/`: Phoenix. The MCP HTTP endpoint and the operator LiveView
  dashboard (`operator_live.ex`).
- `cli/`: Node CLI.
- `integrations/pi/`: Pi plugin, loaded by direct file reference
  (`pi -e …/agent-talk.ts`) with no build step. Update it by updating the checkout
  and restarting the Pi session.
- `integrations/polling/`: shared MCP client and inbox watcher used by the plugin.

## Conventions and gotchas

- Two durable stores: ring membership in `data/memberships.json`, the conversation
  archive in `data/history.sqlite3`. Never delete `data/`. It holds live runtime
  membership.
- Never print node or ring tokens. Errors and smokes omit response bodies for this
  reason. The operator dashboard exposes no tokens.
- The inbox copy shape is defined once, in `@message_fields` (`hub.ex`). Recovery
  rebuilds that shape from the archive, so live sends and restored copies must match.
  Keep the one definition authoritative.
- Ids come from a global counter (`System.unique_integer` in `Hub.allocate_id`).
  Under `async: true` tests, ids climb across the whole run, so a low numeric ring or
  node id hardcoded as a "nonexistent" sentinel can collide with a real allocated id.
  Use a non-numeric sentinel such as `"ring-absent"`.
