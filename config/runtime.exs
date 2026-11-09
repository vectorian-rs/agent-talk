import Config

default_file = Path.join(__DIR__, if(config_env() == :prod, do: "prod.toml", else: "dev.toml"))
file = AgentTalk.Config.path(System.argv(), default_file)
settings = AgentTalk.Config.load!(file)

config :agent_talk, settings ++ [config_file: Path.expand(file)]

if config_env() == :test do
  config :agent_talk, membership_file: nil
end

config :agent_talk, AgentTalk.Web.Endpoint,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
  check_origin: settings[:allowed_origins]
