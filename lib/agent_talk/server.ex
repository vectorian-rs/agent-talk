defmodule AgentTalk.Server do
  @moduledoc false
  use Anubis.Server,
    name: "agent-talk",
    version: "0.1.0",
    capabilities: [:tools],
    instructions: """
    Register once as pm or implementation and retain your node_id and token.
    Use list_nodes to discover agents. Use communicate with action=send and either
    to=[node IDs] or to_role=implementation for fan-out; use action=receive to drain
    your inbox. Poll receive between tasks; this server does not wake idle agents.
    Authenticated communicate calls and registration renew your presence lease
    (five minutes by default; register_node returns the configured duration).
    """

  component(AgentTalk.Tools.ListNodes)
  component(AgentTalk.Tools.RegisterNode)
  component(AgentTalk.Tools.Communicate)
end
