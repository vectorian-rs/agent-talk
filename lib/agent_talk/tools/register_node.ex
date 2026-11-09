defmodule AgentTalk.Tools.RegisterNode do
  @moduledoc """
  A PM starts a ring with role=pm and receives its ring_token and onboarding template.
  Other agents join with their role and that ring_token; the server assigns unique IDs.
  Renew with role, node_id and your private token. After expiry, join again with role
  and ring_token for a new identity. Save every successful response and follow its instructions.
  """
  use Anubis.Server.Component, type: :tool, name: "register_node"

  schema do
    field(:node_id, :string,
      min_length: 1,
      max_length: 64,
      description: "Server-assigned ID, supplied only when renewing"
    )

    field(:role, :string,
      required: true,
      min_length: 1,
      max_length: 64,
      description: "Your role, e.g. pm, worker or reviewer. pm without ring_token creates a ring."
    )

    field(:ring_token, :string,
      description: "PM's ring invitation token, required for a new join"
    )

    field(:token, :string,
      description: "Your private node token for renewal; never use the shared ring_token here"
    )

    field(:project, :string,
      min_length: 1,
      max_length: 128,
      description: "Repository or project label"
    )

    field(:name, :string,
      min_length: 1,
      max_length: 128,
      description: "Display name, e.g. hiko / w-1"
    )
  end

  @impl true
  def execute(args, frame), do: AgentTalk.tool_reply(AgentTalk.Hub.register(args), frame)
end
