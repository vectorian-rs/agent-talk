defmodule AgentTalk.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :agent_talk

  @session_options [
    store: :cookie,
    key: "_agent_talk_operator",
    signing_salt: "operator-session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.mjs)
  )

  plug(Plug.Static,
    at: "/assets/liveview",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.Static, at: "/", from: :agent_talk, only: ~w(assets))

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.CodeReloader)
    plug(Phoenix.LiveReloader)
  end

  plug(Plug.Session, @session_options)
  plug(AgentTalk.Web.Router)
end
