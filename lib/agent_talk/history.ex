defmodule AgentTalk.History do
  @moduledoc "SQLite conversation archive. Contains message content and public identities, never registration fields."
  alias Exqlite.Sqlite3, as: SQLite

  @fields [
    :id,
    :ring_id,
    :from,
    :message,
    :sent_at,
    :to,
    :from_role,
    :from_name,
    :to_names,
    :project
  ]
  @schema """
  CREATE TABLE IF NOT EXISTS messages (
    sequence INTEGER PRIMARY KEY,
    message_id TEXT NOT NULL UNIQUE,
    ring_id TEXT NOT NULL,
    sent_date TEXT NOT NULL,
    event_json TEXT NOT NULL,
    collected_json TEXT NOT NULL DEFAULT '{}'
  );
  CREATE INDEX IF NOT EXISTS messages_day_ring ON messages(sent_date, ring_id, sequence);
  PRAGMA user_version = 1;
  """

  def open(nil), do: {:ok, nil}

  def open(file) do
    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- private_file(file),
         :ok <- valid_header(file),
         {:ok, db} <- SQLite.open(file) do
      result =
        with :ok <-
               SQLite.execute(
                 db,
                 "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;"
               ),
             {:ok, [[version]]} <- query(db, "PRAGMA user_version", []) do
          case version do
            0 -> SQLite.execute(db, @schema)
            1 -> :ok
            _ -> {:error, :unsupported_history_version}
          end
        end

      case result do
        :ok ->
          {:ok, db}

        _ ->
          SQLite.close(db)
          {:error, :history_unavailable}
      end
    else
      _ -> {:error, :history_unavailable}
    end
  end

  def close(nil), do: :ok
  def close(db), do: SQLite.close(db)

  def recent(nil, _limit), do: {:ok, []}

  def recent(db, limit) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT event_json, collected_json FROM messages ORDER BY sequence DESC LIMIT ?",
             [limit]
           ) do
      decode_rows(rows)
    end
  end

  def last_counter(nil), do: {:ok, 0}

  def last_counter(db) do
    case query(
           db,
           "SELECT COALESCE(MAX(CAST(SUBSTR(message_id, 9) AS INTEGER)), 0) FROM messages",
           []
         ) do
      {:ok, [[number]]} -> {:ok, number}
      _ -> {:error, :history_unavailable}
    end
  end

  def record(nil, _request, _reply, _state, _at), do: :ok

  def record(db, {:communicate, %{action: "send"}}, {:ok, %{message_id: id}}, state, _at) do
    event = Enum.find(state.messages, &(&1.id == id))

    with {:ok, json} <- Jason.encode(Map.take(event, @fields)) do
      run(
        db,
        "INSERT INTO messages(message_id, ring_id, sent_date, event_json) VALUES (?, ?, ?, ?)",
        [id, event.ring_id, String.slice(event.sent_at, 0, 10), json]
      )
    end
  end

  def record(
        db,
        {:communicate, %{action: "receive", node_id: recipient}},
        {:ok, %{messages: messages}},
        _state,
        at
      ) do
    if messages == [] do
      :ok
    else
      transaction(db, fn ->
        Enum.reduce_while(messages, :ok, fn message, :ok ->
          result =
            with {:ok, [[json]]} <-
                   query(db, "SELECT collected_json FROM messages WHERE message_id = ?", [
                     message.id
                   ]),
                 {:ok, collected} when is_map(collected) <- Jason.decode(json),
                 {:ok, updated} <- Jason.encode(Map.put_new(collected, recipient, at)) do
              run(db, "UPDATE messages SET collected_json = ? WHERE message_id = ?", [
                updated,
                message.id
              ])
            else
              _ -> {:error, :history_unavailable}
            end

          case result do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end)
    end
  end

  def record(_db, _request, _reply, _state, _at), do: :ok

  def daily(file, day, ring \\ nil)

  def daily(nil, _day, _ring), do: {:error, :history_disabled}

  def daily(file, %Date{} = day, ring) do
    with {:ok, db} <- SQLite.open(file, mode: :readonly) do
      try do
        sql = "SELECT event_json, collected_json FROM messages WHERE sent_date = ?"

        {sql, args} =
          if ring,
            do: {sql <> " AND ring_id = ?", [Date.to_iso8601(day), ring]},
            else: {sql, [Date.to_iso8601(day)]}

        with {:ok, rows} <- query(db, sql <> " ORDER BY sequence", args) do
          decode_rows(rows)
        end
      after
        SQLite.close(db)
      end
    else
      _ -> {:error, :history_unavailable}
    end
  end

  def markdown(day, events) do
    header =
      "# AgentTalk conversation — #{Date.to_iso8601(day)} (UTC)\n\nMessages: #{length(events)}\n\n"

    entries =
      Enum.map(events, fn event ->
        recipients =
          Enum.map_join(event.to, ", ", fn id -> "#{Map.get(event.to_names, id, id)} (#{id})" end)

        collected =
          Enum.map_join(event.to, "\n", fn id ->
            "#{id}: #{Map.get(event.collected_at, id, "not collected")}"
          end)

        text =
          "Ring: #{event.ring_id}\nProject: #{event.project || "unspecified"}\nSent: #{event.sent_at}\nFrom: #{event.from_name} (#{event.from})\nTo: #{recipients}\n\n#{event.message}\n\nCollection:\n#{collected}"

        fence_size =
          Regex.scan(~r/`+/, text)
          |> Enum.map(fn [run] -> byte_size(run) + 1 end)
          |> Enum.max(fn -> 3 end)
          |> max(3)

        fence = String.duplicate("`", fence_size)
        "## #{event.id}\n\n#{fence}text\n#{text}\n#{fence}\n\n"
      end)

    [header | entries]
  end

  defp private_file(file) do
    case File.open(file, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)
        File.chmod(file, 0o600)

      {:error, :eexist} ->
        File.chmod(file, 0o600)

      error ->
        error
    end
  end

  defp valid_header(file) do
    with {:ok, io} <- File.open(file, [:read, :binary]) do
      try do
        case IO.binread(io, 16) do
          :eof -> :ok
          "SQLite format 3\0" -> :ok
          _ -> {:error, :invalid_history_file}
        end
      after
        File.close(io)
      end
    end
  end

  defp transaction(db, action) do
    with :ok <- SQLite.execute(db, "BEGIN IMMEDIATE") do
      result = with :ok <- action.(), do: SQLite.execute(db, "COMMIT")
      if result != :ok, do: SQLite.execute(db, "ROLLBACK")
      result
    end
  end

  defp query(db, sql, args) do
    with {:ok, statement} <- SQLite.prepare(db, sql) do
      try do
        with :ok <- SQLite.bind(statement, args), do: SQLite.fetch_all(db, statement)
      after
        SQLite.release(db, statement)
      end
    end
  end

  defp run(db, sql, args) do
    case query(db, sql, args) do
      {:ok, _rows} -> :ok
      _ -> {:error, :history_unavailable}
    end
  end

  defp decode_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn [event_json, collected_json], {:ok, events} ->
      with {:ok, event} when is_map(event) <- Jason.decode(event_json),
           {:ok, collected} when is_map(collected) <- Jason.decode(collected_json),
           true <-
             Enum.all?(
               ~w(id ring_id from message sent_at from_role from_name),
               &is_binary(event[&1])
             ),
           true <- is_list(event["to"]) and Enum.all?(event["to"], &is_binary/1),
           true <- is_map(event["to_names"]),
           true <- Enum.all?(collected, fn {id, at} -> id in event["to"] and is_binary(at) end) do
        public = Map.new(@fields, &{&1, event[Atom.to_string(&1)]})
        received = Enum.filter(public.to, &Map.has_key?(collected, &1))

        {:cont,
         {:ok, [Map.merge(public, %{received_by: received, collected_at: collected}) | events]}}
      else
        _ -> {:halt, {:error, :invalid_history}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end
end
