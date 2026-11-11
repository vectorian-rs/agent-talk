defmodule AgentTalk.MembershipStore do
  @moduledoc "Private, atomically replaced membership snapshots; messages remain in memory."

  @node_fields [:node_id, :role, :ring_id, :token, :project, :name, :last_seen]

  def node_fields, do: @node_fields

  def load(nil), do: {:ok, %{nodes: %{}, rings: %{}, next_id: 0}}

  def load(file) do
    case File.read(file) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> load(nil)
      {:error, reason} -> {:error, reason}
    end
  end

  def save(nil, _state), do: :ok

  def save(file, state) do
    data = %{
      version: 1,
      next_id: state.next_id,
      rings: state.rings,
      nodes: Enum.map(state.nodes, fn {_id, node} -> Map.take(node, @node_fields) end)
    }

    temporary =
      file <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".tmp"

    result =
      with {:ok, contents} <- Jason.encode(data),
           :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- write_private(temporary, contents) do
        File.rename(temporary, file)
      end

    File.rm(temporary)
    result
  end

  defp write_private(file, contents) do
    with {:ok, io} <- File.open(file, [:write, :binary, :exclusive]) do
      result =
        with :ok <- File.chmod(file, 0o600),
             :ok <- IO.binwrite(io, contents) do
          :file.sync(io)
        end

      File.close(io)
      result
    end
  end

  defp decode(contents) do
    with {:ok, %{"version" => 1, "next_id" => counter, "rings" => rings, "nodes" => nodes}} <-
           Jason.decode(contents),
         true <- is_integer(counter) and counter >= 0 and is_map(rings) and is_list(nodes),
         true <-
           Enum.all?(rings, fn {id, token} -> valid_id?(id, "ring", counter) and text?(token) end),
         true <- Enum.all?(nodes, &valid_node?(&1, rings, counter)),
         true <- length(Enum.uniq_by(nodes, & &1["node_id"])) == length(nodes) do
      restored =
        Map.new(nodes, fn node ->
          {node["node_id"], Map.new(@node_fields, &{&1, node[Atom.to_string(&1)]})}
        end)

      {:ok, %{nodes: restored, rings: rings, next_id: counter}}
    else
      _ -> {:error, :invalid_membership_file}
    end
  end

  defp valid_node?(node, rings, counter) when is_map(node) do
    valid_id?(node["node_id"], "node", counter) and
      Map.has_key?(rings, node["ring_id"]) and text?(node["token"]) and text?(node["role"]) and
      Enum.all?(["project", "name"], &(is_nil(node[&1]) or text?(node[&1]))) and
      text?(node["last_seen"]) and match?({:ok, _, _}, DateTime.from_iso8601(node["last_seen"]))
  end

  defp valid_node?(_, _, _), do: false

  defp valid_id?(id, prefix, counter) when is_binary(id) do
    case String.split(id, "-", parts: 2) do
      [^prefix, number] ->
        case Integer.parse(number) do
          {n, ""} -> n > 0 and n <= counter
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_id?(_, _, _), do: false
  defp text?(value), do: is_binary(value) and value != ""
end
