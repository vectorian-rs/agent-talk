# AgentTalk

A small Elixir MCP server for a PM coordinating agents in an isolated ring. Run one
shared server and point every agent at `http://127.0.0.1:4000/mcp`.

A **node** is a registered agent. A **ring** groups a PM and its invited agents.
Agents declare their roles, such as `pm`, `worker` or `reviewer`.
Presence uses a renewable lease: an agent is considered connected while its
registration is active. The default lease lasts 24 hours (86,400 seconds).

## Run

Requires Elixir 1.18+ and a compatible Erlang/OTP version.

```sh
mix deps.get
mix run --no-halt
```

Development live reload is enabled by default. Saving UI modules under
`lib/agent_talk/web/` or files under `priv/static/` updates the browser without
restarting the server, preserving registrations and messages. Dependency and
configuration changes still require a restart. Reloading is disabled in test
and production environments.

Connect your MCP clients using Streamable HTTP. For clients that accept this
JSON configuration:

```json
{
  "mcpServers": {
    "agent-talk": {
      "url": "http://127.0.0.1:4000/mcp"
    }
  }
}
```

Every agent must use the same running server to share registrations and messages.
The server assigns every agent an ID. Save its complete registration response privately.

## Configuration

Server settings come from `config/dev.toml` by default (`config/prod.toml` in a
production build). Both files start with:

```toml
port = 4000
node_ttl_seconds = 86400
message_history_limit = 50
```

Choose a file explicitly without environment variables:

```sh
mix run --no-halt -- --config config/dev.toml
mix run --no-halt -- --config config/prod.toml
```

Run one server, using the desired file. Numeric settings must be positive integers;
the port must be 1..65535. Missing, malformed or unknown settings stop startup.
The startup log identifies the file, lease duration and history limit.
Configuration edits require a coordinated restart and clear in-memory state.

Browser origins default to `http://localhost:<port>` and `http://127.0.0.1:<port>`.
To change them, add an `allowed_origins` array to the TOML file. Requests without
an `Origin` header remain accepted. The UI session secret is generated at startup;
no application settings are read from environment variables.

## Live operator UI

Open **http://127.0.0.1:4000/** in a browser after starting the server. The operator
view shows connected agents, messages from sender to recipients, and collection
status. Updates arrive over a WebSocket as agents register, send, or collect
messages. Expired agents disappear automatically.

The UI uses **Phoenix LiveView and Phoenix PubSub** with OpexOpt's original CSS
tokens, base styles, layout, and locally served fonts. It supports light/dark
themes, message search, and filtering by agent. No Node.js build step is required.

The shared operator history retains the **last 50 successful sends** by default,
as set by `message_history_limit`, newest first. A broadcast occupies one entry
and lists all its recipients. Reading the UI never drains an agent inbox. `Collected` means a
recipient fetched a message; it does not mean the task is complete. History
survives inbox reads and registration expiry, and resets when the hub restarts.

To watch a sample conversation, keep the server and browser open, then run this
in another terminal:

```sh
mix run --no-start examples/demo.exs --url http://127.0.0.1:4000
```

This creates a separate demo ring on the existing server and sends only
between its members. Substitute your port if needed.

## Three tools

| Tool | Purpose |
| --- | --- |
| `register_node` | Create a ring, join through an invitation, or renew your membership. |
| `list_nodes` | Discover active members of your ring, optionally filtered by role. |
| `communicate` | Send within your ring, or receive messages from your inbox. |

Examples show tool arguments, wrapped by the client in `tools/call`.

A new PM creates a ring with one argument:

```json
{"role": "pm"}
```

The response contains `node_id`, `ring_id`, `role`, a private node `token`, the
shared `ring_token`, `expires_in_seconds` and `instructions`. PMs also receive
`onboarding_prompt_template`. Fill its `<ROLE>` and `<RING_TOKEN>` placeholders
to prepare another agent's private startup prompt. Never put the PM's private
node token in that prompt.

An invited agent chooses its role and joins:

```json
{"role": "worker", "ring_token": "<RING_TOKEN_FROM_PM>"}
```

Roles use 1..64 letters, digits, underscores, dots or hyphens; `all` is reserved
for broadcasts. Roles are declared labels, not authorization or human approval.
Joining returns a new ID and private token. IDs are assigned from a monotonic
counter and never reused within the running Erlang VM, including after node
expiry or a hub restart. Clients cannot choose IDs.

**Save every successful registration response before another authenticated
call.** Replace the previous credentials atomically with file mode `0600`, using
a stable local session name such as `.agent-talk/pm.json` or `.agent-talk/w-1.json`.
The folder is ignored. Each session owns its file; never print credentials in
logs, commits or issue comments. Share only the ring invitation in private
onboarding prompts. Both tokens are generated from 32 random bytes hashed with
SHA-256. The ring token admits members; the private token authenticates one node.

Discover members using your assigned ID and private token:

```json
{"node_id": "<YOUR_ID>", "token": "<YOUR_PRIVATE_TOKEN>", "role": "worker"}
```

Omit `role` to list every active member of your ring. Neither token appears in
these results. The PM broadcasts through `communicate`:

```json
{
  "action": "send",
  "node_id": "<PM_ID>",
  "token": "<PM_PRIVATE_TOKEN>",
  "to_role": "worker",
  "message": "Implement your assigned part and reply when ready."
}
```

Use `to: ["<DISCOVERED_ID>", "<ANOTHER_ID>"]` for selected members, or
`to_role: "all"` for every other member. Broadcasts exclude the sender.
Discovery, direct sends and broadcasts cannot cross rings. An invalid recipient
rejects the whole send. Workers receive with their own credentials:

```json
{"action": "receive", "node_id": "<YOUR_ID>", "token": "<YOUR_PRIVATE_TOKEN>"}
```

Receive returns FIFO messages with `id`, `from`, `ring_id`, `message` and
`sent_at`, then empties the inbox. Reply using `action: "send"` and the PM's
**discovered or invited ID**. Project labels such as CeleraTax's `w-1` remain
separate from the server-assigned transport ID.

## Startup prompts

For a new PM session:

```text
Follow this project's PM instructions. Resume this session's saved AgentTalk
registration, or create a ring with register_node(role="pm"). Follow the returned
instructions and prepare onboarding prompts from its template. The human starts
other sessions; do not start them yourself.
```

For an invited agent, use the PM's returned template with its ring token and the
agent's chosen role. The server's initialization instructions, tool descriptions
and registration response explain the protocol; no extra onboarding tool is needed.

## Leases and recovery

The default membership lease is 86,400 seconds; use the returned duration.
Authenticated `list_nodes`, `communicate` and renewal reset only the caller's
lease. Discovery and communication do this even if later argument validation
fails. Incoming messages and open MCP connections do not renew a recipient.

Renew an active membership with the same role, ID and private token:

```json
{"role": "worker", "node_id": "<YOUR_ID>", "token": "<YOUR_PRIVATE_TOKEN>"}
```

Renewal preserves both tokens, ID, ring and inbox. Roles and rings cannot be
changed through renewal. An idle host timer can renew around every third of the
lease duration, without an LLM turn or endless agent polling. `receive` drains
messages, so use registration for a heartbeat.

Expiry occurs at the exact lease boundary; calls remove expired nodes before
acting, and a one-second sweep removes idle members. Expiry discards the node's
inbox. Rejoin with **role and saved ring_token**, save the new ID/token, rediscover
members and reconcile work with the project's durable record. An expired ID
cannot be renewed or reclaimed. A fresh role-only PM call creates a different
ring. Rings and invitations remain valid until the server restarts.

| Tool error | Recovery |
| --- | --- |
| `invalid ring token` | Get the current invitation from the PM; a server restart invalidates old rings. |
| `invalid node token` | Reload this session's saved credentials. If lost, rejoin with the invitation as a new identity and notify the PM; this does not take over the old ID. |
| `node is not registered or has expired; join again with role and ring_token` | Rejoin the same ring, save the new identity and recover assigned work. |
| `unknown or expired recipients: …` / `no matching recipients` | Discover current members in your ring before retrying. Nothing was queued. |

These are `isError: true` tool results, not transport failures. There is no
unauthenticated reset of another node's token. An inbox holds 1,000 messages;
a message is limited to 65,536 UTF-8 bytes. `delivered_to` means queued at that
instant, not collected or completed: recipient expiry can discard a just-queued
message. Require an application-level reply before treating a handoff as
accepted. Operator history can still show the uncollected send afterward.

The operator UI observes all rings without draining inboxes or exposing tokens.
History, rings, credentials and inboxes are in memory. A full server restart
loses them all; coordinate it with the operator. The HTTP listener binds to
`127.0.0.1` for trusted local use. Remote deployment needs an authenticated HTTPS
boundary and an appropriate browser-origin allowlist.

## Demo and checks

Run an isolated PM → two workers → PM exchange on an automatically assigned port:

```sh
mix run --no-start examples/demo.exs
```

For a three-client smoke test covering invitations, renewal, expiry, fresh IDs,
mailbox loss, recovered delivery and ring isolation:

```sh
mix run --no-start examples/lease_smoke.exs
```

The smoke test uses its own hub, port and two-second lease without changing
config files, connecting to the trial server or printing tokens.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Built with [Anubis MCP](https://hexdocs.pm/anubis_mcp/readme.html), Bandit,
Phoenix LiveView/PubSub and a supervised GenServer. The MCP API has three tools.
