# AgentTalk

A small Elixir MCP server for a PM coordinating implementation agents. Run one
shared server and point every agent at `http://127.0.0.1:4000/mcp`.

Here, a **node is a registered AI agent**, with role `pm` or `implementation`.
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
Each agent registers its own unique ID and keeps the returned private token.

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

This connects to the existing server with unique demo agent names and sends only
between those demo agents. Substitute your port if needed.

## Three tools

| Tool | Purpose |
| --- | --- |
| `register_node` | Register an agent, or renew its registration using its token. |
| `list_nodes` | List active agents, optionally filtering by role. |
| `communicate` | Send to one or many agents, or receive messages from your inbox. |

Examples below show **tool arguments**, which your MCP client wraps in `tools/call`.

Register the PM, then have each worker register with role `implementation` and
its own `node_id`, such as `backend` or `frontend`:

```json
{"node_id": "pm", "role": "pm"}
```

The result includes `node_id`, `role`, `token`, and `expires_in_seconds`. Save
**every successful registration response before another authenticated call**,
including renewals and recovery after expiry. Replace previous credentials;
if saving fails, stop. For files, use an atomic replacement with mode `0600`
under the ignored `.agent-talk/<node-id>.json`. Serialize registration, saving
and authenticated calls within each node's owning client. Never print tokens
or include them in messages, logs or commits. `list_nodes` never exposes tokens.

Discover all workers with `list_nodes`:

```json
{"role": "implementation"}
```

The PM broadcasts through `communicate`:

```json
{
  "action": "send",
  "node_id": "pm",
  "token": "<pm-token>",
  "to_role": "implementation",
  "message": "Implement your part of the feature and reply when ready."
}
```

For selected recipients, replace `to_role` with `"to": ["backend", "frontend"]`.
Use `"to_role": "all"` to reach every other active agent. Role broadcasts exclude
the sender. A successful send returns a shared `message_id` and `delivered_to`.

Each worker polls its inbox through the same `communicate` tool:

```json
{"action": "receive", "node_id": "backend", "token": "<backend-token>"}
```

Receive returns messages in arrival order, including `id`, `from`, `message`,
and `sent_at`, then empties that inbox. A worker replies to the PM:

```json
{
  "action": "send",
  "node_id": "backend",
  "token": "<backend-token>",
  "to": ["pm"],
  "message": "Backend implementation is ready for review."
}
```

The PM reads replies using `communicate` with `action: "receive"` and its own credentials.

## Leases and recovery

The TOML setting `node_ttl_seconds` controls the lease. The application converts
it to milliseconds for the hub. Verify `expires_in_seconds: 86400` in a successful
registration response when using the default configuration. A running hub keeps
its startup settings; changing a file does not alter active registrations.

| Event | Lease, token and inbox |
| --- | --- |
| Registration on a free or expired ID | New token and empty inbox; any supplied old token is ignored. |
| Registration before expiry | Current token required; preserves token and inbox, resets the full lease. |
| Authenticated `communicate` | Resets only the caller's lease, even if send/receive argument validation fails. |
| Incorrect token, discovery, open MCP session, incoming message | Does not extend that node's lease. |

Expiry occurs at the exact boundary `last authenticated activity + TTL`. Every
hub call removes expired nodes before acting; a one-second sweep also removes
idle nodes. Expiry, registration, authentication and fan-out are serialized in
one GenServer. Concurrent re-registrations of an expired ID have one winner.

An idle **host/client timer** can renew with `register_node` at roughly one third
of the returned lease duration. Use the latest saved token and save each response.
This needs no LLM turn or endless agent polling. Registration preserves the
inbox; `receive` drains it. Without a timer, choose a lease long enough for normal
pauses and re-register on resume after expiry. Healthy MCP connectivity and an
open Pi session do not maintain presence or wake agents. Check `receive` between
tasks or when the operator resumes the agent.

| Tool error text | Recovery |
| --- | --- |
| `node is not registered or has expired; call register_node` | Re-register and save the response; recover assigned work from the project's durable record. |
| `invalid node token` | Reload the latest saved registration response. |
| `node_id is already registered; its token is required to renew it` | Resume the owning client with its current token. If lost, stop stale retries and wait for expiry, or ask the operator to approve a distinct ID and update addressing. |
| `unknown or expired recipients: …` / `no matching recipients` | Resume and re-register intended recipients before retrying. Failed fan-out queues nothing. |

These are `isError: true` tool results, not transport failures. Absent and expired
IDs share an error because expired records are deleted. There is no token reset
or unauthenticated takeover of an active ID. Do not restart a shared server to
recover one node's credentials.

A successful send means queued **at that instant**. It does not renew recipients:
expiry can discard a just-queued message, while operator history still shows it
as uncollected. Require a worker's application-level reply before treating a
handoff as accepted. Keep assignments in the project's durable work record and
reconcile it after expiry; do not blindly resend work that may have been acted on.

## Behavior

- Sends are atomic across recipients. Unknown recipients, no matching role, or a
  full inbox reject the send. Duplicate recipients receive one copy.
- An inbox holds up to 1,000 messages; each message is at most 65,536 UTF-8 bytes.
- `delivered_to` means queued. Agents must poll and execute tasks themselves.
  Receiving removes messages before the HTTP response reaches the client; this
  minimal server has no acknowledgment, retry deduplication, or durable delivery.
- The HTTP listener binds to `127.0.0.1` for trusted local clients. Registration
  tokens protect agent identities; deploying across machines needs an authenticated
  HTTPS boundary and an appropriate origin allowlist.

## Demo and checks

With port 4000 free, run a self-contained PM → two workers → PM exchange over
real MCP HTTP connections. The demo starts its own server and exits afterward:

```sh
mix run examples/demo.exs
```

For registration, renewal, idle expiry, stale-token rejection, mailbox loss and
recovered delivery with **three independent MCP clients**:

```sh
mix run --no-start examples/lease_smoke.exs
```

This starts its own hub and HTTP listener on an OS-assigned loopback port. It
never connects to or restarts the trial server. It prints checks without tokens,
keeps credentials in memory, and exits after about five seconds. It sets a
two-second lease only inside its own process, without changing any config file.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

The project uses [Anubis MCP](https://hexdocs.pm/anubis_mcp/readme.html) for protocol
handling, Bandit for HTTP, a supervised GenServer for registration and mailboxes,
and [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)
for the live operator UI. The MCP interface still exposes exactly three tools.
