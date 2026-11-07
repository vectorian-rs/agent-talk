defmodule AgentTalk.Router do
  @moduledoc false
  use Plug.Router

  plug(:check_origin)
  plug(:match)
  plug(:dispatch)

  forward("/mcp",
    to: Anubis.Server.Transport.StreamableHTTP.Plug,
    init_opts: [server: AgentTalk.Server]
  )

  forward("/", to: AgentTalk.Web.Endpoint)

  defp check_origin(conn, _opts) do
    origins = get_req_header(conn, "origin")
    allowed = Application.fetch_env!(:agent_talk, :allowed_origins)

    if origins == [] or (length(origins) == 1 and hd(origins) in allowed) do
      conn
    else
      conn |> send_resp(403, "Origin not allowed") |> halt()
    end
  end
end
