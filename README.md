# AgentTalk

A small Elixir MCP server for a PM coordinating implementation agents. Run one
shared server and point every agent at `http://127.0.0.1:4000/mcp`.

Here, a **node is a registered AI agent**, with role `pm` or `implementation`.
Presence uses a renewable lease: an agent is considered connected while its
registration is active. The default lease lasts five minutes.

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

## Live operator UI

Open **http://127.0.0.1:4000/** in a browser after starting the server. The operator
view shows connected agents, messages from sender to recipients, and collection
status. Updates arrive over a WebSocket as agents register, send, or collect
messages. Expired agents disappear automatically.

The UI uses **Phoenix LiveView and Phoenix PubSub** with OpexOpt's original CSS
tokens, base styles, layout, and locally served fonts. It supports light/dark
themes, message search, and filtering by agent. No Node.js build step is required.

The shared operator history retains only the **last 50 successful sends** in
memory, newest first. A broadcast occupies one history entry and lists all its
recipients. Reading the UI never drains an agent inbox. `Collected` means a
recipient fetched a message; it does not mean the task is complete. History
survives inbox reads and registration expiry, and resets when the hub restarts.

To watch a sample conversation, keep the server and browser open, then run this
in another terminal:

```sh
AGENT_TALK_URL=http://127.0.0.1:4000 mix run --no-start examples/demo.exs
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

The result includes `node_id`, `role`, `token`, and `expires_in_seconds`. Retain
the token for subsequent calls; `list_nodes` never exposes tokens.

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

## Behavior

- Have agents poll `receive` between tasks and before the lease expires. An
  authenticated `communicate` call renews presence. Long-running agents can renew
  with `register_node`, supplying their existing ID, role and token.
- Registrations and inboxes live in memory. Restarting the server or letting a
  registration expire discards that node's inbox and token. Register again after
  expiry. Discovery and message routing exclude expired nodes.
- Sends are atomic across recipients. Unknown recipients, no matching role, or a
  full inbox reject the send. Duplicate recipients receive one copy.
- An inbox holds up to 1,000 messages; each message is at most 65,536 UTF-8 bytes.
- `delivered_to` means queued. Agents must poll and execute tasks themselves.
  Receiving removes messages before the HTTP response reaches the client; this
  minimal server has no acknowledgment, retry deduplication, or durable delivery.
- The HTTP listener binds to `127.0.0.1` for trusted local clients. Registration
  tokens protect agent identities; deploying across machines needs an authenticated
  HTTPS boundary and an appropriate origin allowlist.

Change the port or lease duration:

```sh
PORT=4100 NODE_TTL_SECONDS=900 mix run --no-halt
```

Requests without an `Origin` header are accepted. Browser requests must match
`http://localhost:<port>` or `http://127.0.0.1:<port>`. Override the allowlist with
the comma-separated `ALLOWED_ORIGINS` environment variable if needed.

## Demo and checks

With port 4000 free, run a self-contained PM → two workers → PM exchange over
real MCP HTTP connections. The demo starts its own server and exits afterward:

```sh
mix run examples/demo.exs
```

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

The project uses [Anubis MCP](https://hexdocs.pm/anubis_mcp/readme.html) for protocol
handling, Bandit for HTTP, a supervised GenServer for registration and mailboxes,
and [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)
for the live operator UI. The MCP interface still exposes exactly three tools.
