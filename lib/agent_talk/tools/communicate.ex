defmodule AgentTalk.Tools.Communicate do
  @moduledoc """
  Send to one or many agents, or receive and remove all messages in your inbox.
  For send, supply message and either to (node IDs) or to_role (pm, implementation or all).
  Role broadcasts exclude the sender. Receive takes only action, node_id and token.
  Authenticated calls renew only the caller's lease; sends do not renew recipients.
  A send queues messages; recipient expiry can discard them before collection.
  Call receive between tasks to collect messages; use register_node for an idle heartbeat.
  """
  use Anubis.Server.Component, type: :tool, name: "communicate"

  schema do
    field(:action, {:enum, ["send", "receive"]}, required: true)
    field(:node_id, :string, required: true, description: "Your registered node ID")
    field(:token, :string, required: true, description: "Your private registration token")
    field(:to, {:list, :string}, description: "One or more recipient node IDs")
    field(:to_role, {:enum, ["pm", "implementation", "all"]}, description: "Broadcast target")
    field(:message, :string, description: "Message text (up to 65536 bytes)")
  end

  @impl true
  def execute(args, frame), do: AgentTalk.tool_reply(AgentTalk.Hub.communicate(args), frame)
end
