# AgentTalk

A local Elixir MCP server for a PM assigning work to other agents. It holds
inboxes and shows message traffic in a browser. You launch the agents and
provide their role instructions.

**PM assigns → worker receives, works and replies → PM handles the result.**

A **node** is one registered agent; a **ring** is a PM and its invited team.
The server assigns IDs. Labels such as `w-1` identify workers in your project.
Pi displays the checkout name and membership filename, such as `hiko / w-1`.
Use the left-hand ring selector to watch one team's agents and messages.

| Client | Message pickup |
| --- | --- |
| Pi with the optional extension | Checks every 10 seconds without model turns for empty checks; wakes idle agents or queues a follow-up while busy. |
| MCP alone, including Claude and Codex | Ask agents to receive manually, or wire the [Claude Code inbox hook](#claude-code-inbox-hook) to surface pending mail at the edges of a turn. Automatic Claude/Codex adapters are not implemented. |

AgentTalk is optional and preserves your repository's work and approval rules.
See the [integration contract](integrations/README.md) for host responsibilities.

## Operator dashboard

The server serves a browser dashboard at http://127.0.0.1:4000/. It reads all hub
state and exposes no tokens. Use the ring selector to watch one team's registered
agents and message traffic, and download a day's conversation archive (see
[Server configuration and limits](#server-configuration-and-limits)).

The dashboard also acts on the selected ring:

- **Evict a node** to remove a stuck or stale agent. Its inbox is discarded and it
  disappears from every connected view; the agent must rejoin to return.
- **Broadcast a message** to every current member of the ring. Each member receives
  one copy and the message appears in the log as sender `Operator`. A confirmation
  names how many agents will receive it. A broadcast is a one-way announcement: the
  `operator` sender has no inbox, so agents reply to their PM over the normal send
  path, not to the operator.

Both actions are local and need no token, matching the trusted dashboard.

## Onboard a repository with Pi

This guide starts one PM and two workers on the same machine. Requirements:
Elixir 1.18+, compatible Erlang/OTP, and Pi with a working model configuration
(tested with Pi 1.5.0). Replace the example paths with your own.

### 1. Start the server

Keep AgentTalk in its own checkout:

```sh
git clone https://github.com/vectorian-rs/agent-talk.git /path/to/agent-talk
cd /path/to/agent-talk
mix deps.get
mix run --no-halt -- --config config/dev.toml
```

Skip cloning if already installed. Leave the server running; every agent must
connect to it. Open **http://127.0.0.1:4000/** for the operator UI.

### 2. Prepare your project

In another terminal:

```sh
cd /path/to/your-repo
pi mcp add agent-talk --local --url http://127.0.0.1:4000/mcp
pi mcp list
mkdir -p .agent-talk
chmod 700 .agent-talk
```

This writes `.pi/mcp.json`. In a trusted checkout, confirm `agent-talk` connects
with `register_node`, `list_nodes` and `communicate`.

Add to **your project's** `.gitignore`:

```gitignore
/.agent-talk/
```

Each session owns a private registration file: `pm.json`, `w-1.json` or `w-2.json`.
Agents create these from server responses; you do not fill in credentials.

Add these shared rules to your project's chosen instruction entry point and
ensure your host reads them:

```text
When AgentTalk is selected:
- Follow the repository's role, scope, claim, verification and approval rules.
- Save every complete successful registration atomically, mode 0600, in your
  session's .agent-talk file before another authenticated call.
- Keep tokens out of logs, commits and issue comments. Share only ring
  invitations in private onboarding prompts; never share private node tokens.
- Receive on host notifications; verify the sender and assignment against
  the project record.
- Send receipt, acceptance or blocked, then results through AgentTalk.
  Do not acknowledge acknowledgments.
- The human launches PM and workers; the host polls. No empty model polling.
Otherwise use the repository's usual workflow.
```

### 3. Launch the PM

From your project's root:

```sh
pi -e /path/to/agent-talk/integrations/pi/agent-talk.ts \
  --agent-talk-membership .agent-talk/pm.json
```

The extension waits for the registration file. Paste:

```text
Follow this session's existing instructions as PM, with automatic inbox handling.
Renew the membership in .agent-talk/pm.json using role, node_id and token.
Create a ring with role=pm only if no saved membership exists. Inactivity does
not expire membership. If saved membership is missing or revoked, ask the operator;
do not silently rejoin or create a replacement ring.
Save each complete successful response to that file under the shared rules.

Prepare private invitations from the returned template for w-1 and w-2,
both role=worker, using .agent-talk/w-1.json and .agent-talk/w-2.json.
Include the PM ID, ring ID and ring invitation, never your private node token.
Tell each worker to follow its existing instructions, resume only a matching role/ring or
join with role=worker and ring_token, save its full response, verify the PM
through list_nodes, and send "joined <label>". Include automatic inbox
handling and the shared reply rules. I will launch the workers.

Handle replies and coordinate authorized work under the project's approval gates.
```

### 4. Launch the workers

Open two terminals in your project's root. In the first:

```sh
pi -e /path/to/agent-talk/integrations/pi/agent-talk.ts \
  --agent-talk-membership .agent-talk/w-1.json
```

In the second:

```sh
pi -e /path/to/agent-talk/integrations/pi/agent-talk.ts \
  --agent-talk-membership .agent-talk/w-2.json
```

Paste each PM invitation into its matching session. It supplies the ring
invitation and PM ID, with instructions equivalent to this worker prompt
(use `w-2` and its file for the second worker):

```text
Follow this session's existing instructions as worker w-1, with automatic inbox handling.
Use .agent-talk/w-1.json. Resume only if its role and ring match this invitation;
otherwise join with role=worker and the invited ring_token. Save the complete
response under the shared rules before another call.
Verify the invited PM through list_nodes, then send "joined w-1" to its ID.
Handle verified PM requests and send receipt, acceptance or blocked, and results.
```

The PM maps labels to verified sender IDs. Separate assignments target those
IDs; the shared `worker` role does not distinguish workers.

### 5. Check the team

Ask the PM:

```text
Ask each worker to reply with its logical label. Report when both replies
arrive. Do not change project files.
```

Allow for inbox checks and model execution. Expect three UI registrations and
messages in both directions. Then give the PM a project task and keep sessions
open; only goals and required approvals need human input.

`Collected` means fetched, not accepted or completed. `Last activity` includes
host checks and does not prove the model is working.

## Daily use and recovery

Reuse saved files to resume; use fresh files for a new team. Never share one
membership between live agents or fork the PM to create workers. Server restarts
preserve rings and registrations; leave agents running and Pi reconnects
automatically. Inactivity and downtime affect presence, not membership. With the conversation archive
enabled, queued mail a recipient has not collected is restored at startup;
without it, inboxes are memory only, so recover unfinished work from the
project record. Message history is archived
in SQLite; recent entries return to the UI after restart.
Rings already lost by an older server must be recreated once.

Pi controls: `/agent-talk status`, `/agent-talk off`, and
`/agent-talk on .agent-talk/w-1.json` (use your session's file). Enter one command
at a time. Paths must end in `.json`. Status shows the path, last successful
check and last requested turn. Escape pauses automatic turns while heartbeats
continue; your next prompt or `on` resumes them. Only `off` persists a disable.

| Problem | Action |
| --- | --- |
| Old tool schema | `/mcp reconnect agent-talk`; `/reload` after MCP config or extension updates. |
| Unread mail | Check the extension, matching credential path and notification-handling prompt. Three wake-ups for the same unread message produce a stalled status. |
| Lost connection | The host retries with backoff without model turns. |
| Offline member | Resume using the same saved identity; authenticated activity makes it online again. |
| Missing/revoked membership | Stop and ask the operator. Do not silently rejoin. Old IDs already removed by an earlier server cannot be recovered by this upgrade. |
| `invalid node token` | Reload the correct credentials. If lost or exposed, ask the operator to revoke and explicitly replace that membership. |
| `invalid ring token` | Check the server and its membership file. A lost/deleted store needs a new PM ring and worker invitations; client files cannot restore it. |
| Unknown/revoked recipient | Rediscover and confirm its identity before resending. Rejected sends queue nothing. |

## Claude Code inbox hook

Claude Code has no background watcher, so it notices mail only when asked, and an
MCP-only client has no background delivery between turns. A small hook closes that
gap: `agent-talk inbox` reads a saved registration and reports the pending count
**without receiving**, so Claude can decide to call `communicate(action="receive")`
through the MCP tool. The hook samples the count at the edges of a turn — session
start and prompt submit.

```bash
# Prints: AgentTalk: 2 pending message(s) for node-3 (next message-9). ...
#     or: AgentTalk: inbox empty for node-3.
node /path/to/agent-talk/cli/agent-talk.mjs \
  inbox /path/to/.agent-talk/delivery/pm.json --server http://127.0.0.1:4000/mcp
```

Wire it into `~/.claude/settings.json` (or a project `.claude/settings.json`) so
its output joins the session context at the start of each session and before each
prompt. Replace the membership path and server with your own; drop `--server`
when you run the command from a project that has an `agent-talk.toml`.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "node /path/to/agent-talk/cli/agent-talk.mjs inbox /path/to/.agent-talk/delivery/pm.json --server http://127.0.0.1:4000/mcp" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
        "command": "node /path/to/agent-talk/cli/agent-talk.mjs inbox /path/to/.agent-talk/delivery/pm.json --server http://127.0.0.1:4000/mcp" } ] }
    ]
  }
}
```

Each run makes two short HTTP requests, so on a slow or unreachable server the
`UserPromptSubmit` hook adds that latency to every prompt; wire only `SessionStart`
if that matters. A failed check is non-blocking — it exits non-zero and the prompt
still proceeds.

The hook only reports; add the AgentTalk MCP server to Claude Code so it can
`register_node`, `list_nodes` and `communicate` from the session itself.

## Membership file examples

Agents save complete `register_node` responses. Files need not exist at launch.
Pi wraps the registration in `structuredContent`, alongside `content` and `isError`.
The extension accepts that result or the registration object shown below.
Credentials are placeholders; server instruction text is abbreviated.

`.agent-talk/pm.json`:

```json
{
  "node_id": "node-2",
  "ring_id": "ring-1",
  "role": "pm",
  "token": "<PM_PRIVATE_TOKEN>",
  "ring_token": "<SHARED_RING_INVITATION>",
  "expires_in_seconds": null,
  "presence_timeout_seconds": 60,
  "online": true,
  "last_seen": "2026-11-08T12:00:00Z",
  "pending_messages": 0,
  "instructions": "<SERVER_INSTRUCTIONS>",
  "onboarding_prompt_template": "<SERVER_ONBOARDING_TEMPLATE>"
}
```

`.agent-talk/w-1.json`:

```json
{
  "node_id": "node-3",
  "ring_id": "ring-1",
  "role": "worker",
  "token": "<WORKER_PRIVATE_TOKEN>",
  "ring_token": "<SHARED_RING_INVITATION>",
  "expires_in_seconds": null,
  "presence_timeout_seconds": 60,
  "online": true,
  "last_seen": "2026-11-08T12:00:00Z",
  "pending_messages": 0,
  "instructions": "<SERVER_INSTRUCTIONS>"
}
```

Both share a ring and invitation; IDs and private tokens differ. The filename
`w-1.json` is a logical label. Messages stay on the server; `last_seen` and
`pending_messages` are registration snapshots.

## Server configuration and limits

Settings come from TOML, without OS environment-variable overrides.
Development defaults to `config/dev.toml`; production builds to `config/prod.toml`:

```toml
port = 4000
presence_timeout_seconds = 60
message_history_limit = 50
membership_file = "../data/memberships.json"
history_file = "../data/history.sqlite3"
```

Select with `--config`. Choosing `prod.toml` does not change the build mode.
Numeric settings must be positive integers; ports are 1..65535. Invalid or unknown
settings stop startup. The startup log reports version, config, presence timeout,
history limit, membership file and conversation archive.

`presence_timeout_seconds` controls when an inactive member is shown offline;
it never deletes membership or inboxes. The legacy `node_ttl_seconds` key is
accepted as a presence-timeout alias so existing configs still start. Do not
specify both. Existing config values remain unchanged until explicitly edited.

`membership_file` resolves relative to the TOML file. The default private
`data/memberships.json` stores rings, credentials, labels, last activity and the
ID counter, using atomic replacements with mode `0600`. Keep it across restarts,
back it up privately and use a separate file for each server. An unreadable or
corrupt store stops startup; failed writes reject the operation. The default
directory is gitignored. Changing this path selects different membership state.

`history_file` also resolves relative to the TOML file. SQLite records every
successful send and each recipient's collection time before acknowledging that
operation; failed archive writes preserve inboxes and return an error. The private
database and its journal files live in the gitignored data directory. Membership
credentials remain in the separate membership file and are excluded from archive
records. Message bodies are stored as sent. A corrupt archive — including any
row that inbox recovery cannot decode — stops startup rather than faking empty
inboxes; to start anyway, move the database aside (the moved file keeps the
history, queued mail is lost).

For daily review, choose a date under **Conversation archive · UTC**, select the
current ring or **All rings**, and download Markdown. The export includes all that day's messages, even those outside
the live window. `/history/export?date=2026-11-10` exports all rings; add `&ring=ring-123`
to select one. Times and day boundaries are UTC. Reviewing/exporting never drains
inboxes. SQLite uses [WAL](https://sqlite.org/wal.html) and exports use a separate
read-only connection.

Recording starts when this version is activated. Previously lost in-memory history
cannot be reconstructed, and the first activating restart cannot restore mail that
was never archived. From then on, with the archive enabled, a message acknowledged with
`delivered_to` is either collected (a receive removed it, even if that
response was lost in transit) or discarded by explicit recipient eviction — never
dropped by a hub restart.
Archive retention is independent of the UI limit and has no automatic deletion.

For another port, update the MCP URL and add
`--agent-talk-url http://127.0.0.1:<port>/mcp` to each Pi launch.

The server binds to `127.0.0.1` for trusted local use. Browser origins default to
localhost/127.0.0.1 at that port; `allowed_origins` overrides them. Requests without
`Origin` are accepted. The UI secret is generated at startup. Remote access needs
authenticated HTTPS and an appropriate origin allowlist.

- Rings, registered identities and archived conversations survive restarts.
  With the archive enabled, queued uncollected mail is restored even for offline
  members and shows as `Queued`; without it, live inboxes are memory only.
- Presence timestamps are periodically flushed, so a crash can slightly
  underreport recent activity. It cannot expire an identity or discard its mail.
- Explicit eviction revokes membership and discards its inbox. Receive removes
  mail before the response, so failures can lose it. Keep durable tasks/results
  in your project's record. Offline inboxes are still subject to capacity limits.
- Each inbox holds 1,000 messages; messages are at most 65,536 UTF-8 bytes.
- UI history defaults to the last 50 successful sends across rings. A broadcast
  is one entry. This bounds the live window, not the SQLite archive.

### Upgrading an existing server

Back up `memberships.json` and the conversation archive privately before an
operator-approved restart. The existing version-1 membership store is read
without a format migration: all identities still present in it are retained,
including members whose last activity is older than the presence timeout.
Saved client credentials do not need to be replaced. Identities already deleted
by an older server cannot be resurrected; resolve those individually with the
operator rather than resetting the ring. An older server used for rollback
would enforce its old expiry policy again, so do not downgrade blindly.

Registration now returns `expires_in_seconds: null` and a separate
`presence_timeout_seconds`. Clients should pace heartbeats from the latter.
`list_nodes` includes offline members and exposes `online`; use that field when
selecting currently reachable agents, not membership existence alone.

## MCP reference

| Tool | Arguments |
| --- | --- |
| `register_node` | Create: `{"role":"pm"}`. Join: `{"role":"worker","ring_token":"<INVITATION>"}`. Renew: `{"role":"worker","node_id":"<ID>","token":"<PRIVATE_TOKEN>"}`. Optional `project` and `name` supply display labels. |
| `list_nodes` | Own `node_id`/`token` and optional `role` filter. Returns registered ring members (with `online` presence) and the caller's `inbox` metadata without consuming mail. Optional `project` and `name` update only the caller's labels. |
| `communicate` | Own `node_id`/`token` and `action`. Send: `message` and either `to: ["<ID>", ...]` or `to_role`. Receive: no send fields; drains the FIFO inbox. |

Clients wrap these arguments in `tools/call`. Broadcasts exclude the sender;
`to_role: "all"` targets every other ring member. Discovery and delivery stay
inside the ring. Explicit `to` sends are all-or-nothing: invalid recipients or
full inboxes reject the entire send, with full members named by ID and display
name. Role sends and operator broadcasts skip full inboxes and deliver to the
remaining members. If every inbox is full, the operation fails with `inbox_full`;
no message ID or archive entry is created.

Save every complete registration via a same-directory temporary file, mode `0600`,
then rename over the previous file. Roles use 1..64 letters, digits, underscores,
dots or hyphens; `all` is reserved. Roles confer no authorization or human approval.
The saved ID counter prevents reuse across restarts, including after eviction.
Tokens hash 32 random bytes with SHA-256.

Authenticated discovery, communication and renewal update only the caller's
presence, even if discovery/communication later fail validation. Incoming mail
and open connections do not prove recipient activity. Membership itself has no
inactivity deadline. Resume preserves ID, tokens, ring and inbox, and cannot
change role/ring. Invitations and identities survive restarts while the
membership file is retained. Online means recent authenticated contact, not that
the model is working. `not_registered` means absent or explicitly revoked, not
offline; `invalid_token` means authentication failed.
A fresh role-only PM call creates another ring.

`inbox` contains `pending_messages` and `next_message_id` (null when empty), even
with a role filter. Received messages contain `id`, `from`, `from_name`,
`from_role`, `ring_id`, `message` and `sent_at`, so a recipient reads who sent a
message without a separate `list_nodes` call. Send returns
`message_id`, `delivered_to` and `skipped`. Each skipped entry contains `node_id`,
`name` and `reason: "inbox_full"`; an unskipped send returns `skipped: []`.
Skipped members never receive that message, even after they free capacity or the
broker restarts. Retry only skipped recipients, not the whole group. History,
collection counts and restart recovery include only actual recipients.
Delivery means queued, so require an application reply before acceptance.
Tool errors use `isError: true`.

## Development and examples

These developer checks are not required to onboard a real team:

| Script | Purpose |
| --- | --- |
| `examples/demo.exs` | Scripted PM/two-worker exchange, isolated by default. `--url http://127.0.0.1:4000` uses a separate demo ring on an existing server. |
| `examples/lease_smoke.exs` | Isolated durable-membership, offline presence, return, mail retention, revocation and ring-isolation checks. |
| `examples/pi_smoke.exs` | Three real Pi processes exchange messages before and after an isolated server process restart, using unchanged credentials; no paid model calls or trial-server access. |

From the AgentTalk checkout:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
node --test cli/*.test.mjs integrations/polling/*.test.mjs integrations/pi/*.test.mjs
mix run --no-start examples/demo.exs
mix run --no-start examples/lease_smoke.exs
mix run --no-start examples/pi_smoke.exs
```

Integration tests use Node 24+. The Pi smoke validates mechanics; onboarding
step 5 checks your actual agents.

The LiveView/PubSub UI uses vendored OpexOpt CSS/fonts without a Node build.
Development reload watches `lib/agent_talk/web/` and `priv/static/`; dependency or
config changes require a coordinated restart. Reload is off in test/production.

Built with [Anubis MCP](https://hexdocs.pm/anubis_mcp/readme.html), Bandit and
Phoenix, with a supervised GenServer for membership and mailboxes.
