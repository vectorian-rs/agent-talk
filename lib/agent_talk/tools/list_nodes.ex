defmodule AgentTalk.Tools.ListNodes do
  @moduledoc "List registered agents with an unexpired presence lease, optionally filtered by role."
  use Anubis.Server.Component, type: :tool, name: "list_nodes"

  schema do
    field(:role, {:enum, ["pm", "implementation"]}, description: "Optional role filter")
  end

  @impl true
  def execute(args, frame),
    do: AgentTalk.tool_reply(AgentTalk.Hub.list_nodes(Map.get(args, :role)), frame)
end
