defmodule AgentTalk.Tools.ListNodes do
  @moduledoc """
  List active members of your ring, optionally filtered by role. Also returns your
  inbox's pending_messages and next_message_id without removing messages, even with
  a role filter. Authenticates and renews only your lease. Host integrations can
  poll this metadata and wake your session; the session receives and handles mail.
  Each listed node carries its role, name, project and purpose, so you can pick a
  recipient by what it does. Optional project, name and purpose labels update only
  the authenticated caller's own entry.
  """
  use Anubis.Server.Component, type: :tool, name: "list_nodes"

  schema do
    field(:node_id, :string, required: true, description: "Your server-assigned node ID")
    field(:token, :string, required: true, description: "Your private node token")
    field(:role, :string, min_length: 1, max_length: 64, description: "Optional role filter")

    field(:project, :string,
      min_length: 1,
      max_length: 128,
      description: "Your repository or project label"
    )

    field(:name, :string,
      min_length: 1,
      max_length: 128,
      description: "Your display name, e.g. hiko / w-1"
    )

    field(:purpose, :string,
      min_length: 1,
      max_length: 128,
      description: "One line describing what you do, so peers can find you by capability"
    )
  end

  @impl true
  def execute(args, frame),
    do: AgentTalk.tool_reply(AgentTalk.Hub.list_nodes(args), frame)
end
