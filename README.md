# AgentTalk

AgentTalk lets a PM agent assign work to other agents and receive their results.
One local Elixir server holds the inboxes and shows message traffic in a browser.

For a real project, you start the server, launch your PM and workers, and give
them their role instructions. With the optional Pi integration enabled, incoming
mail starts an agent turn or queues a follow-up while the agent is busy:

**PM assignment → worker receives → worker works and replies → PM handles result.**

A **node** is one registered agent. A **ring** is a PM and its invited team.
The server assigns IDs; names such as `w-1` are your project's logical labels.

| Client | Current support |
| --- | --- |
| Pi | MCP tools plus optional automatic inbox checks and wake-ups. |
| Other MCP clients, including Claude and Codex | Register, send and receive through MCP. Automatic wake-up adapters are not implemented yet. |

AgentTalk is optional: your repository's work rules and approval gates stay in
place. The server routes messages; your role prompts determine what agents do.

## Onboard a repository with Pi

This guide uses one PM and two workers on the same machine. Keep AgentTalk in its
own checkout. Replace `/path/to/agent-talk` and `/path/to/your-repo` below with your
actual paths. You need Elixir 1.18+ and compatible Erlang/OTP for the server, plus
Pi with a working model configuration for the real agents. The integration has
been tested with Pi 1.5.0.

### 1. Start the shared server

In a terminal for AgentTalk:

```sh
git clone https://github.com/vectorian-rs/agent-talk.git /path/to/agent-talk
cd /path/to/agent-talk
mix deps.get
mix run --no-halt -- --config config/dev.toml
```

If you already have the checkout, start it from there. Leave this terminal open.
Use the same running server for all team members. Open
**http://127.0.0.1:4000/** for the operator UI.

### 2. Prepare your project

In another terminal, at your project's root:

```sh
cd /path/to/your-repo
pi mcp add agent-talk --local --url http://127.0.0.1:4000/mcp
pi mcp list
mkdir -p .agent-talk
chmod 700 .agent-talk
```

The MCP command writes project configuration to `.pi/mcp.json`. Check that
`agent-talk` is connected and exposes `register_node`, `list_nodes` and
`communicate`. Pi loads project configuration in a trusted checkout.

Add this line to **your project's** `.gitignore`:

```gitignore
/.agent-talk/
```

That directory holds private registration files. Each live agent owns a different
file: `pm.json`, `w-1.json` and `w-2.json`. Agents create those files during
registration; you do not fill in IDs or tokens yourself. See the
[membership file examples](#membership-file-examples) for their contents.

Add the following to your shared agent instructions, usually `AGENTS.md`, and
ensure your agent host reads it:

```text
When the operator selects AgentTalk:
- Follow this repository's role, scope, claims, verification and approval rules.
- Save every successful registration response privately and atomically in this
  session's .agent-talk file, mode 0600, before another authenticated call.
- Keep both tokens out of logs, commits and issue comments. Share only the
  ring invitation in private onboarding prompts; never share a private node token.
- When the host notifies you of inbox mail, receive and handle it automatically.
  Verify the sender and assignment against the project record.
- Send actual replies through AgentTalk: receipt, acceptance or blocked, and
  results as appropriate. Do not reply to acknowledgments.
- The human starts the PM and workers. The host checks inboxes; do not spend
  model turns on empty polling.
Without AgentTalk, use the repository's usual workflow.
```

### 3. Launch the PM

From your project's root, start a real Pi session with the inbox extension:

```sh
pi -e /path/to/agent-talk/integrations/pi/agent-talk.ts \
  --agent-talk-membership .agent-talk/pm.json
```

The extension waits until the agent saves its registration. Paste this prompt:

```text
Act as this repository's PM using AgentTalk. Automatic inbox handling is enabled.

Read .agent-talk/pm.json privately if it exists and renew that membership with
role, node_id and token. Otherwise create a ring with register_node(role="pm").
Follow the registration response. Save every successful complete response
atomically in .agent-talk/pm.json with mode 0600 before another call.
If an existing membership expired, rejoin with its saved role and ring_token;
do not create another PM ring as recovery. Stop if its ring invitation is invalid.

Prepare two private invitations from the returned onboarding template, for
logical workers w-1 and w-2, both with role worker. Include the PM ID, ring ID,
ring invitation and each worker's credential-file path: .agent-talk/w-1.json
or .agent-talk/w-2.json. Each invitation must tell the worker to save its full
registration privately, verify the PM, send "joined <label>", handle inbox
notifications automatically, send receipt and acceptance or blocked, perform
authorized work and send results. Keep project approval gates and do not
acknowledge acknowledgments. Never include your private node token.
I will launch the workers.

Handle worker messages automatically and coordinate only authorized work.
Keep this repository's human approval gates.
```

The PM's response supplies the private invitations. A ring invitation admits
members; a private node token authenticates one member. Keep them separate.

### 4. Launch and invite the workers

Open two more terminals in your project's root. In the first:

```sh
pi -e /path/to/agent-talk/integrations/pi/agent-talk.ts \
  --agent-talk-membership .agent-talk/w-1.json
```

In the second:

```sh
pi -e /path/to/agent-talk/integrations/pi/agent-talk.ts \
  --agent-talk-membership .agent-talk/w-2.json
```

Paste the matching PM invitation into each session. It provides the real ring
invitation and PM ID, with worker instructions equivalent to this text (using
`w-2` and `.agent-talk/w-2.json` for the second worker):

```text
Act as this repository's worker w-1. Automatic inbox handling is enabled.
Use .agent-talk/w-1.json for your complete private registration, saved atomically
with mode 0600 before another call. Resume only if its role and ring match
this invitation; otherwise join using role=worker and the invited ring_token.

Verify the invited PM through list_nodes, then send "joined w-1" to that PM ID.
On inbox notification, receive messages and handle verified PM requests under
the repository's worker instructions. Send receipt and acceptance or blocked,
perform authorized work, and send results to the PM. A local print is not a
reply. Do not acknowledge acknowledgments or bypass human approval gates.
```

The PM maps each logical worker label to the sender's actual server ID. Separate
assignments target those IDs; a shared `worker` role does not distinguish workers.

### 5. Check the real team

Give the PM this small first request:

```text
Ask each worker to reply with its logical label. Report when both replies
arrive. Do not change project files.
```

Within the normal 10-second inbox-check interval, the idle workers should wake,
receive the request and reply. The PM then picks up the replies automatically.
A busy agent handles its queued notification after its current work finishes.

The UI should show three registrations and messages in both directions.
`Collected` means fetched from an inbox, not accepted or completed.
`Last activity` includes host checks; it does not prove the model is working.

You can now give the PM a project task. Keep all sessions open. The human supplies
goals and required approvals; message pickup does not require manual resumes.

## Daily use and troubleshooting

Resume an existing team with its saved files. Use fresh files for a new team,
and never share one membership file between live sessions. Start workers as
separate sessions rather than forks of the PM.

After a full server restart, move old membership files aside privately and
repeat steps 3–4 to create a new PM ring and invitations. Recover unfinished work
from the project record; the old inboxes are gone.

| Situation | Action |
| --- | --- |
| Check automatic inbox state | Run `/agent-talk status` in that Pi session. |
| Stop automatic wake-ups | Run `/agent-talk off`. |
| Resume after Escape/cancellation | Run `/agent-talk on .agent-talk/w-1.json`, using that session's file. |
| Tools have an old schema | Run `/mcp reconnect agent-talk`; use `/reload` after changing MCP configuration outside Pi. |
| Mail remains unread | Check that the extension is loaded, the membership path matches the agent's saved file, and the role prompt handles notifications. After three wake-ups for the same unread message, the extension reports stalled. |
| Connection is unavailable | The watcher retries with backoff, without model turns for empty checks. |
| Registration expired | Rejoin with the saved role and ring invitation, save the new identity, rediscover peers and reconcile work with the project record. |
| `invalid node token` | Reload saved credentials. If lost, rejoin as a new identity using the ring invitation; another node's token cannot be reset or reclaimed. |
| `invalid ring token` | Ask the operator for the current invitation. A full server restart invalidates old rings. |
| Unknown or expired recipient | Rediscover the member and confirm its identity before resending. A rejected send queues nothing. |

The MCP connection provides tools. The Pi extension provides wake-ups. Connecting
MCP alone does not start an idle agent turn. Without the extension, ask the agent
to check its inbox manually. See the [integration contract](integrations/README.md)
for the boundary between host code and role prompts.

Two known issues from the current implementation review remain open:

- The Pi watcher checks every 10 seconds. Leases of 10 seconds or less can expire
  between checks, including while waiting for a newly saved registration. Keep
  the default 24-hour lease for this onboarding path.
- After navigating conversation branches, `/reload` and reopening Pi can restore
  different monitoring states. Check `/agent-talk status` and explicitly select
  `on` or `off` after that operation.

## Membership file examples

These are complete saved registrations from `register_node`. The files do not
need to exist when you launch Pi: the extension waits for the agent to register
and save its response. The values below are illustrative placeholders, with
server instructions abbreviated. Each agent saves the actual full response.

`.agent-talk/pm.json`:

```json
{
  "node_id": "node-2",
  "ring_id": "ring-1",
  "role": "pm",
  "token": "<PM_PRIVATE_TOKEN>",
  "ring_token": "<SHARED_RING_INVITATION>",
  "expires_in_seconds": 86400,
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
  "expires_in_seconds": 86400,
  "last_seen": "2026-11-08T12:00:00Z",
  "pending_messages": 0,
  "instructions": "<SERVER_INSTRUCTIONS>"
}
```

The team shares a `ring_id` and ring invitation; each agent has its own
`node_id` and private `token`. The filename `w-1.json` is your logical label,
not the server ID. Messages remain on the server. Fields such as `last_seen`
and `pending_messages` are snapshots from registration, not a live inbox.

## Server configuration and limits

Application settings come from TOML, with no OS environment-variable overrides.
`config/dev.toml` is the default; a production build defaults to `config/prod.toml`.
Both contain:

```toml
port = 4000
node_ttl_seconds = 86400
message_history_limit = 50
```

Select a file with `--config` as in step 1. Selecting `prod.toml` changes settings;
it does not change the Elixir build mode. Positive integer settings are required,
the port must be 1..65535, and unknown or malformed settings stop startup. The
startup log reports the version, config file, lease and history limit.

If you change the port, update the MCP URL and pass the same URL to every Pi
session with `--agent-talk-url http://127.0.0.1:<port>/mcp`.

Browser origins default to localhost and 127.0.0.1 at the configured port.
An optional `allowed_origins` TOML array changes them. Requests without an
`Origin` header are accepted. The UI session secret is generated at startup.

The listener binds to `127.0.0.1` for trusted local use. Remote access needs an
authenticated HTTPS boundary and an appropriate browser-origin allowlist.

Rings, registrations and inboxes are **in memory**. Coordinate restarts:
a full server restart clears them. Expiry also discards a node's inbox, and
receiving removes messages before the client response. This is best-effort
coordination; keep durable work and results in your project's issue/task record.

Each inbox holds up to 1,000 messages; each message is at most 65,536 UTF-8 bytes.
The operator log retains the last 50 successful sends by default, across rings.
A broadcast occupies one log entry. Reading the UI never consumes inboxes.

## MCP reference

| Tool | Arguments and behavior |
| --- | --- |
| `register_node` | Fresh PM: `{"role":"pm"}`. Invited member: `{"role":"worker","ring_token":"<INVITATION>"}`. Renew: `{"role":"worker","node_id":"<ID>","token":"<PRIVATE_TOKEN>"}`. |
| `list_nodes` | Own `node_id` and `token`, plus optional `role` filter. Returns active members of the caller's ring and the caller's `inbox` metadata without removing mail. |
| `communicate` | Own `node_id` and `token`, plus `action`. Send takes `message` and either `to: ["<ID>", ...]` or `to_role`. Receive takes no send fields and drains the FIFO inbox. |

These are tool arguments; the MCP client wraps them in `tools/call`.
`to_role: "all"` targets every other member of the caller's ring. Role broadcasts
exclude the sender. Discovery, direct messages and broadcasts cannot cross rings.
Fan-out is atomic: an invalid recipient or full inbox rejects the whole send.

Registration returns `node_id`, `ring_id`, `role`, private `token`, shared
`ring_token`, `expires_in_seconds`, `instructions` and presence/inbox fields.
PMs also receive `onboarding_prompt_template`. Save the complete response, replacing
the previous file through a same-directory temporary file and rename, mode `0600`.

Roles use 1..64 letters, digits, underscores, dots or hyphens; `all` is reserved.
Roles are labels, not authorization or human approval. IDs are assigned from a
monotonic counter and never reused within the running Erlang VM, including after
node expiry or Hub restart. Both tokens use 32 random bytes hashed with SHA-256.

Authenticated discovery, communication and renewal reset only the caller's lease,
even if discovery/communication later fail argument validation. Incoming mail
and an open MCP connection do not renew recipients. Renewal preserves identity,
tokens, ring and inbox; it cannot change role or ring. After expiry, joining with
the invitation returns a new ID/token in the same ring. A fresh role-only PM call
creates another ring. Invitations survive member expiry until the server restarts.

`list_nodes.inbox` contains `pending_messages` and `next_message_id` (null when
empty), even with a role filter. Receive returns messages with `id`, `from`,
`ring_id`, `message` and `sent_at`. Send returns `message_id` and `delivered_to`;
the latter means queued at that instant. Require an application-level reply
before treating work as accepted. Tool errors use `isError: true`.

## Development and examples

These scripts are developer checks; they are not required to onboard a real team.

| Script | Purpose |
| --- | --- |
| `examples/demo.exs` | Scripted PM/two-worker exchange. Isolated by default; `--url http://127.0.0.1:4000` sends demo traffic in a separate ring on an existing server. |
| `examples/lease_smoke.exs` | Three-client registration, renewal, idle expiry, rejoining, delivery and ring-isolation checks on an isolated short-lease server. |
| `examples/pi_smoke.exs` | Three actual Pi processes with a scripted local model verify automatic pickup and replies. No paid model calls or trial-server access. |

Run from the AgentTalk checkout:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
node --test integrations/polling/*.test.mjs integrations/pi/*.test.mjs
mix run --no-start examples/demo.exs
mix run --no-start examples/lease_smoke.exs
mix run --no-start examples/pi_smoke.exs
```

Node 24+ runs the integration tests. The Pi smoke checks transport, tool execution
and wake-up mechanics; it does not evaluate a real model's compliance with project
prompts. Step 5 above checks your configured agents.

The operator UI uses Phoenix LiveView/PubSub and vendored OpexOpt CSS/fonts,
with no Node build step. Development live reload watches `lib/agent_talk/web/`
and `priv/static/`. Dependency/configuration changes require a coordinated restart.
Reloading is disabled in test and production builds.

Built with [Anubis MCP](https://hexdocs.pm/anubis_mcp/readme.html), Bandit and
Phoenix, with a supervised GenServer for membership and mailboxes.
