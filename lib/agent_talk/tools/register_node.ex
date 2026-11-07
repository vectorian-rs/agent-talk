defmodule AgentTalk.Tools.RegisterNode do
  @moduledoc """
  Register an agent or renew its lease with its current token, preserving its inbox.
  After expiry, registration creates a new token and empty inbox. Save every
  successful response before another authenticated call, replacing saved credentials.
  """
  use Anubis.Server.Component, type: :tool, name: "register_node"

  schema do
    field(:node_id, :string,
      required: true,
      min_length: 1,
      max_length: 64,
      description: "Unique agent name, e.g. pm, backend or frontend"
    )

    field(:role, {:enum, ["pm", "implementation"]}, required: true)

    field(:token, :string,
      description: "Token from the latest successful registration, for renewal"
    )
  end

  @impl true
  def execute(args, frame), do: AgentTalk.tool_reply(AgentTalk.Hub.register(args), frame)
end
