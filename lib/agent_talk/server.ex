defmodule AgentTalk.Server do
  @moduledoc false
  use Anubis.Server,
    name: "agent-talk",
    version: "0.1.0",
    capabilities: [:tools],
    instructions: """
    Register as pm or implementation. Save every successful registration response,
    including node_id, token and expires_in_seconds, before another authenticated call.
    Use list_nodes to discover agents. Use communicate with action=send and either
    to=[node IDs] or to_role=implementation for fan-out; use action=receive to drain
    your inbox. Poll receive between tasks; this server does not wake idle agents.
    Authenticated communicate calls and registration renew your presence lease
    (24 hours by default; register_node returns the configured duration).
    Renew before expiry with the saved token. Active renewal preserves the token
    and inbox; after expiry, registration creates a new token and empty inbox.
    An open MCP connection does not renew a node. Idle presence needs a host timer
    calling register_node, or a lease long enough for the human-paced session.
    If a token is lost, recover saved credentials or wait for expiry; an active
    registration cannot be claimed without its current token.
    """

  component(AgentTalk.Tools.ListNodes)
  component(AgentTalk.Tools.RegisterNode)
  component(AgentTalk.Tools.Communicate)
end
