defmodule AgentTalk.ConfigTest do
  use ExUnit.Case, async: true

  alias AgentTalk.{Config, Hub}

  @moduletag :tmp_dir

  test "dev and prod use a 24-hour lease and retain 50 messages" do
    for file <- ["config/dev.toml", "config/prod.toml"] do
      settings = Config.load!(file)
      assert settings[:port] == 4000
      assert settings[:node_ttl_ms] == 86_400_000
      assert settings[:message_history_limit] == 50
    end
  end

  test "hub defaults use the loaded application settings" do
    hub = start_supervised!({Hub, name: nil})
    {:ok, node} = Hub.register(%{node_id: "default-lease", role: "pm"}, hub)
    assert node.expires_in_seconds == 86_400
    assert {:ok, %{history_limit: 50}} = Hub.snapshot(hub)
  end

  test "custom settings convert seconds and derive browser origins from the port", %{tmp_dir: dir} do
    settings =
      dir
      |> write_config(%{"port" => 4100, "node_ttl_seconds" => 3600, "message_history_limit" => 2})
      |> Config.load!()

    assert settings[:port] == 4100
    assert settings[:node_ttl_ms] == 3_600_000
    assert settings[:message_history_limit] == 2
    assert settings[:allowed_origins] == ["http://localhost:4100", "http://127.0.0.1:4100"]
  end

  test "browser origins can be set in TOML", %{tmp_dir: dir} do
    settings =
      dir |> write_config(%{"allowed_origins" => ["https://operator.example"]}) |> Config.load!()

    assert settings[:allowed_origins] == ["https://operator.example"]
  end

  test "invalid settings and unknown keys fail rather than silently falling back", %{tmp_dir: dir} do
    for overrides <- [
          %{"port" => 0},
          %{"port" => 65_536},
          %{"node_ttl_seconds" => 0},
          %{"node_ttl_seconds" => -1},
          %{"node_ttl_seconds" => "86400"},
          %{"message_history_limit" => 0},
          %{"message_history_limit" => 1.5},
          %{"allowed_origins" => "http://localhost:4000"},
          %{"allowed_origins" => [""]},
          %{"node_ttl_second" => 3600}
        ] do
      file = write_config(dir, overrides)
      assert_raise ArgumentError, fn -> Config.load!(file) end
    end
  end

  test "missing required values and malformed or missing files fail startup", %{tmp_dir: dir} do
    file = Path.join(dir, "invalid.toml")
    File.write!(file, "port = 4000\n")
    assert_raise ArgumentError, ~r/node_ttl_seconds/, fn -> Config.load!(file) end
    File.write!(file, "port = [\n")
    assert_raise TomlElixir.Parser.Error, fn -> Config.load!(file) end
    assert_raise File.Error, fn -> Config.load!(Path.join(dir, "missing.toml")) end
  end

  test "config selection uses a file argument or the default" do
    assert Config.path([], "config/dev.toml") == "config/dev.toml"
    assert Config.path(["--config", "config/prod.toml"], "config/dev.toml") == "config/prod.toml"
    assert_raise ArgumentError, fn -> Config.path(["--config"], "config/dev.toml") end
  end

  defp write_config(dir, overrides) do
    values =
      Map.merge(
        %{"port" => 4000, "node_ttl_seconds" => 86_400, "message_history_limit" => 50},
        overrides
      )

    file = Path.join(dir, "settings.toml")

    File.write!(
      file,
      Enum.map_join(values, "\n", fn {key, value} -> "#{key} = #{inspect(value)}" end)
    )

    file
  end
end
