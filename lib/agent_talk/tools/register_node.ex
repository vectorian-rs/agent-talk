defmodule AgentTalk.Tools.RegisterNode do
  @moduledoc "Register an agent and return its private token. Supply that token when renewing an existing node."
  use Anubis.Server.Component, type: :tool, name: "register_node"

  schema do
    field(:node_id, :string,
      required: true,
      min_length: 1,
      max_length: 64,
      description: "Unique agent name, e.g. pm, backend or frontend"
    )

    field(:role, {:enum, ["pm", "implementation"]}, required: true)
    field(:token, :string, description: "Token from the original registration, for renewals")
  end

  @impl true
  def execute(args, frame), do: AgentTalk.tool_reply(AgentTalk.Hub.register(args), frame)
end
