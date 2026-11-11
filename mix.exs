defmodule AgentTalk.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_talk,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {AgentTalk.Application, []}
    ]
  end

  defp deps do
    [
      {:anubis_mcp, "~> 2.2.0"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.43.0"},
      {:toml_elixir, "~> 3.3"},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end
end
