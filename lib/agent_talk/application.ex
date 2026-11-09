defmodule AgentTalk.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    ttl_ms = Application.fetch_env!(:agent_talk, :node_ttl_ms)
    history_limit = Application.fetch_env!(:agent_talk, :message_history_limit)

    children =
      [
        {Phoenix.PubSub, name: AgentTalk.PubSub},
        {AgentTalk.Hub,
         ttl_ms: ttl_ms,
         history_limit: history_limit,
         pubsub: AgentTalk.PubSub,
         membership_file: Application.fetch_env!(:agent_talk, :membership_file)},
        {AgentTalk.Server, transport: {:streamable_http, start: true}},
        AgentTalk.Web.Endpoint
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: AgentTalk.Supervisor]

    Logger.info(
      "AgentTalk v#{Application.spec(:agent_talk, :vsn)} config: " <>
        "#{Application.fetch_env!(:agent_talk, :config_file)}; " <>
        "registration lease: #{div(ttl_ms, 1000)} seconds; message history: #{history_limit}; " <>
        "memberships: #{Application.fetch_env!(:agent_talk, :membership_file) || "memory only"}"
    )

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
