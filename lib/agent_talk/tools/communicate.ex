defmodule AgentTalk.Tools.Communicate do
  @moduledoc """
  Send to one or many agents, or receive and remove all messages in your inbox.
  For send, supply message and either to (node IDs) or to_role (a role or all).
  Discovery, direct messages and broadcasts stay within your ring. Broadcasts exclude
  the sender. Receive takes only action, node_id and your private node token.
  Authenticated calls renew only the caller's lease; sends do not renew recipients.
  A send queues messages; recipient expiry can discard them before collection.
  Call receive between tasks to collect messages; use register_node for an idle heartbeat.
  When answering a specific message, set reply_to to its id so the answer can be
  matched to the task it resolves. Set kind to status or fyi for information the
  recipient should read at its next turn but not wake for; send kind=ack with
  reply_to instead of a receipt message. A status or fyi goes to the PM or one
  peer, never a broadcast.
  Use status to see your own recent sends and which recipients have received each,
  without removing anything.
  """
  use Anubis.Server.Component, type: :tool, name: "communicate"

  schema do
    field(:action, {:enum, ["send", "receive", "status"]}, required: true)
    field(:node_id, :string, required: true, description: "Your registered node ID")
    field(:token, :string, required: true, description: "Your private registration token")
    field(:to, {:list, :string}, description: "One or more recipient node IDs")
    field(:to_role, :string, description: "Role within your ring, or all for every other member")
    field(:message, :string, description: "Message text (up to 65536 bytes)")
    field(:reply_to, :string, description: "Id of the message this send answers")

    field(
      :kind,
      {:enum, ["message", "handoff", "decision", "status", "fyi", "ack"]},
      description:
        "message is the default; status/fyi never wake the recipient; ack records a receipt and queues nothing"
    )

    field(:expects_reply, :boolean,
      description: "Defaults to true for message/handoff/decision and false for status/fyi"
    )
  end

  @impl true
  def execute(args, frame), do: AgentTalk.tool_reply(AgentTalk.Hub.communicate(args), frame)
end
