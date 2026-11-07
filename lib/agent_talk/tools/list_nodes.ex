defmodule AgentTalk.Tools.ListNodes do
  @moduledoc "List active members of your ring, optionally filtered by role. Authenticates and renews only your lease."
  use Anubis.Server.Component, type: :tool, name: "list_nodes"

  schema do
    field(:node_id, :string, required: true, description: "Your server-assigned node ID")
    field(:token, :string, required: true, description: "Your private node token")
    field(:role, :string, min_length: 1, max_length: 64, description: "Optional role filter")
  end

  @impl true
  def execute(args, frame),
    do: AgentTalk.tool_reply(AgentTalk.Hub.list_nodes(args), frame)
end
