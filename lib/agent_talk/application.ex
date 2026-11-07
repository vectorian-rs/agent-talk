defmodule AgentTalk.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: AgentTalk.PubSub},
        {AgentTalk.Hub,
         ttl_ms: Application.fetch_env!(:agent_talk, :node_ttl_ms), pubsub: AgentTalk.PubSub},
        {AgentTalk.Server, transport: {:streamable_http, start: true}},
        AgentTalk.Web.Endpoint
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: AgentTalk.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_children do
    if Application.fetch_env!(:agent_talk, :http_enabled) do
      [
        {Bandit,
         plug: AgentTalk.Router,
         ip: {127, 0, 0, 1},
         port: Application.fetch_env!(:agent_talk, :port)}
      ]
    else
      []
    end
  end
end
