defmodule AgentTalk.Config do
  @moduledoc "Loads and validates server settings from a TOML file."

  @keys ~w(port node_ttl_seconds message_history_limit allowed_origins membership_file)

  def path(argv, default) do
    {options, _rest, invalid} = OptionParser.parse(argv, strict: [config: :string])

    if Enum.any?(invalid, fn {switch, _value} -> switch == "--config" end) do
      raise ArgumentError, "--config requires a TOML file path"
    end

    Keyword.get(options, :config, default)
  end

  def load!(file) do
    data = file |> File.read!() |> TomlElixir.decode!()
    unknown = Map.keys(data) -- @keys

    if unknown != [] do
      raise ArgumentError, "unknown settings in #{file}: #{Enum.join(Enum.sort(unknown), ", ")}"
    end

    port = positive_integer!(data, "port")
    if port > 65_535, do: raise(ArgumentError, "port must be 1..65535")
    ttl_seconds = positive_integer!(data, "node_ttl_seconds")
    history_limit = positive_integer!(data, "message_history_limit")
    membership_file = Map.get(data, "membership_file", "../data/memberships.json")

    unless is_binary(membership_file) and String.trim(membership_file) != "" do
      raise ArgumentError, "membership_file must be a nonempty file path"
    end

    origins =
      Map.get(data, "allowed_origins", ["http://localhost:#{port}", "http://127.0.0.1:#{port}"])

    unless is_list(origins) and Enum.all?(origins, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError, "allowed_origins must be a list of nonempty strings"
    end

    [
      port: port,
      node_ttl_ms: ttl_seconds * 1000,
      message_history_limit: history_limit,
      membership_file: Path.expand(membership_file, Path.dirname(Path.expand(file))),
      allowed_origins: origins
    ]
  end

  defp positive_integer!(data, key) do
    case Map.get(data, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end
end
