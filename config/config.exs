import Config

config :logger, level: :info
config :phoenix, :json_library, Jason

config :agent_talk, AgentTalk.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: false,
  url: [host: "localhost"],
  pubsub_server: AgentTalk.PubSub,
  live_view: [signing_salt: "agent-talk-live"],
  render_errors: [formats: [html: AgentTalk.Web.ErrorHTML], layout: false]

config :agent_talk, http_enabled: config_env() != :test

if config_env() == :dev do
  config :agent_talk, AgentTalk.Web.Endpoint,
    code_reloader: true,
    live_reload: [
      patterns: [
        ~r{priv/static/.*$},
        ~r{lib/agent_talk/web/.*\.(ex|heex)$}
      ]
    ]
end
