import Config

port = String.to_integer(System.get_env("PORT", "4000"))
ttl_seconds = String.to_integer(System.get_env("NODE_TTL_SECONDS", "300"))

if port not in 1..65_535 or ttl_seconds < 1 do
  raise "PORT must be 1..65535 and NODE_TTL_SECONDS must be positive"
end

origins =
  case System.get_env("ALLOWED_ORIGINS") do
    nil -> ["http://localhost:#{port}", "http://127.0.0.1:#{port}"]
    value -> String.split(value, ",", trim: true) |> Enum.map(&String.trim/1)
  end

config :agent_talk, port: port, node_ttl_ms: ttl_seconds * 1000, allowed_origins: origins

config :agent_talk, AgentTalk.Web.Endpoint,
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(64)),
  check_origin: origins
