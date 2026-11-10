defmodule AgentTalk.HistoryTest do
  use ExUnit.Case, async: true
  alias AgentTalk.{History, Hub}
  alias Exqlite.Sqlite3, as: SQLite
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    clock =
      start_supervised!(
        {Agent,
         fn -> %{mono: 0, wall: DateTime.to_unix(~U[2026-11-10 12:00:00Z], :millisecond)} end}
      )

    opts = [
      name: nil,
      ttl_ms: 86_400_000,
      history_limit: 2,
      membership_file: Path.join(dir, "memberships.json"),
      history_file: Path.join(dir, "history.sqlite3"),
      clock: fn -> Agent.get(clock, & &1.mono) end,
      wall_clock: fn -> Agent.get(clock, & &1.wall) end
    ]

    hub = start_supervised!({Hub, opts})
    pm = register(hub, %{role: "pm", project: "example", name: "example / pm"})
    worker = register(hub, %{role: "worker", ring_token: pm.ring_token, name: "example / w-1"})

    %{
      hub: hub,
      pm: pm,
      worker: worker,
      opts: opts,
      clock: clock,
      history_file: opts[:history_file]
    }
  end

  test "archive retains all sends and collections beyond the live limit and restores recent history",
       c do
    ids =
      for n <- 1..5 do
        {:ok, %{message_id: id}} =
          send_message(c, [c.worker.node_id], "Message #{n}: '); DROP TABLE messages; --")

        id
      end

    assert {:ok, %{messages: live, history_persistent: true}} = Hub.snapshot(c.hub)
    assert length(live) == 2
    assert {:ok, %{messages: messages}} = receive_messages(c.hub, c.worker)
    assert Enum.map(messages, & &1.id) == ids
    assert {:ok, archived} = History.daily(c.history_file, ~D[2026-11-10])
    assert Enum.map(archived, & &1.id) == ids
    assert Enum.all?(archived, &(&1.received_by == [c.worker.node_id]))
    assert Enum.all?(archived, &is_binary(&1.collected_at[c.worker.node_id]))

    refute Enum.any?(
             [c.pm.token, c.pm.ring_token, c.worker.token],
             &String.contains?(Jason.encode!(archived), &1)
           ),
           "archive queries must expose message content and public identities only"

    for path <- [c.history_file, c.history_file <> "-wal", c.history_file <> "-shm"],
        File.exists?(path) do
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    stop_supervised!(Hub)
    hub = start_supervised!({Hub, c.opts})
    assert {:ok, %{messages: restored}} = Hub.snapshot(hub)
    assert Enum.map(restored, & &1.id) == Enum.reverse(Enum.take(ids, -2))
    assert Enum.all?(restored, &(&1.received_by == [c.worker.node_id]))
  end

  test "queued messages remain reviewable after restart without pretending volatile inboxes survived",
       c do
    assert {:ok, %{message_id: id}} = send_message(c, [c.worker.node_id], "Uncollected")
    stop_supervised!(Hub)
    hub = start_supervised!({Hub, c.opts})
    assert {:ok, %{messages: [%{id: ^id, pending_to: [], received_by: []}]}} = Hub.snapshot(hub)
    assert {:ok, %{messages: []}} = receive_messages(hub, c.worker)

    assert {:ok, [%{id: ^id, message: "Uncollected", received_by: []}]} =
             History.daily(c.history_file, ~D[2026-11-10])
  end

  test "fan-out collection timestamps are recorded independently for each recipient", c do
    other = register(c.hub, %{role: "worker", ring_token: c.pm.ring_token})
    assert {:ok, _} = send_message(c, [c.worker.node_id, other.node_id], "Task")
    assert {:ok, _} = receive_messages(c.hub, c.worker)
    advance(c.clock, 1000)
    assert {:ok, _} = receive_messages(c.hub, other)
    assert {:ok, [event]} = History.daily(c.history_file, ~D[2026-11-10], c.pm.ring_id)
    assert event.received_by == [c.worker.node_id, other.node_id]
    assert event.collected_at[c.worker.node_id] < event.collected_at[other.node_id]
  end

  test "UTC day and ring filters select exact records in send order", c do
    Agent.update(
      c.clock,
      &%{&1 | wall: DateTime.to_unix(~U[2026-11-09 23:59:59.999Z], :millisecond)}
    )

    assert {:ok, %{message_id: yesterday}} = send_message(c, [c.worker.node_id], "Yesterday")
    advance(c.clock, 1)
    assert {:ok, %{message_id: today}} = send_message(c, [c.worker.node_id], "Today")
    other_pm = register(c.hub, %{role: "pm", project: "other"})
    other = register(c.hub, %{role: "worker", ring_token: other_pm.ring_token})

    assert {:ok, _} =
             Hub.communicate(
               auth(other_pm, %{action: "send", to: [other.node_id], message: "Other ring"}),
               c.hub
             )

    assert {:ok, [%{id: ^yesterday}]} = History.daily(c.history_file, ~D[2026-11-09])
    assert {:ok, [%{id: ^today}]} = History.daily(c.history_file, ~D[2026-11-10], c.pm.ring_id)
    assert {:ok, all} = History.daily(c.history_file, ~D[2026-11-10])
    assert length(all) == 2
    assert {:ok, []} = History.daily(c.history_file, ~D[2026-11-10], "' OR 1=1 --")
  end

  test "archive failures return errors without queueing sends or removing fetched batches", c do
    db = :sys.get_state(c.hub).history_db

    :ok =
      SQLite.execute(
        db,
        "CREATE TRIGGER fail_send BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'test failure'); END;"
      )

    assert {:error, "conversation archive unavailable; message operation was not applied"} =
             send_message(c, [c.worker.node_id], "Rejected")

    assert {:ok, %{messages: []}} = receive_messages(c.hub, c.worker)
    assert {:ok, []} = History.daily(c.history_file, ~D[2026-11-10])
    :ok = SQLite.execute(db, "DROP TRIGGER fail_send")
    assert {:ok, _} = send_message(c, [c.worker.node_id], "First")
    assert {:ok, %{message_id: second}} = send_message(c, [c.worker.node_id], "Second")

    :ok =
      SQLite.execute(
        db,
        "CREATE TRIGGER fail_receive BEFORE UPDATE ON messages WHEN OLD.message_id = '#{second}' BEGIN SELECT RAISE(ABORT, 'test failure'); END;"
      )

    assert {:error, "conversation archive unavailable; message operation was not applied"} =
             receive_messages(c.hub, c.worker)

    assert {:ok, archived} = History.daily(c.history_file, ~D[2026-11-10])

    assert Enum.all?(archived, &(&1.received_by == [])),
           "collection batches must roll back atomically"

    assert {:ok, %{inbox: %{pending_messages: 2}}} = Hub.list_nodes(auth(c.worker), c.hub)
    :ok = SQLite.execute(db, "DROP TRIGGER fail_receive")

    assert {:ok, %{messages: [%{message: "First"}, %{message: "Second"}]}} =
             receive_messages(c.hub, c.worker)
  end

  test "a corrupt archive stops startup without overwriting the file", c do
    db = :sys.get_state(c.hub).history_db
    stop_supervised!(Hub)
    assert {:error, :connection_closed} = SQLite.prepare(db, "SELECT 1")
    File.write!(c.history_file, "not a SQLite database")
    assert {:error, _} = start_supervised({Hub, c.opts})
    assert File.read!(c.history_file) == "not a SQLite database"
  end

  test "retained archive IDs are not reused when membership state is recreated", c do
    :sys.replace_state(c.hub, &%{&1 | next_id: 9_000_000_000_000})
    assert {:ok, %{message_id: first}} = send_message(c, [c.worker.node_id], "Before reset")
    stop_supervised!(Hub)
    File.rm!(c.opts[:membership_file])
    hub = start_supervised!({Hub, c.opts})
    pm = register(hub, %{role: "pm"})
    worker = register(hub, %{role: "worker", ring_token: pm.ring_token})

    assert {:ok, %{message_id: second}} =
             send_message(%{c | hub: hub, pm: pm}, [worker.node_id], "After reset")

    assert first != second
    assert String.to_integer(String.replace_prefix(second, "message-", "")) > 9_000_000_000_000
    assert {:ok, events} = History.daily(c.history_file, ~D[2026-11-10])
    assert Enum.map(events, & &1.id) == [first, second]
  end

  test "Markdown export keeps message text literal even when it contains fences and HTML", c do
    body = "pick up #482\n````\n<script>alert(1)</script>\nNo source edits."
    assert {:ok, _} = send_message(c, [c.worker.node_id], body)
    assert {:ok, events} = History.daily(c.history_file, ~D[2026-11-10])
    text = IO.iodata_to_binary(History.markdown(~D[2026-11-10], events))
    assert text =~ body
    assert text =~ "`````text"
    assert text =~ "(UTC)"
    assert text =~ c.pm.ring_id
  end

  defp register(hub, args) do
    {:ok, node} = Hub.register(args, hub)
    node
  end

  defp auth(node, args \\ %{}), do: Map.merge(%{node_id: node.node_id, token: node.token}, args)

  defp send_message(c, recipients, text),
    do: Hub.communicate(auth(c.pm, %{action: "send", to: recipients, message: text}), c.hub)

  defp receive_messages(hub, node), do: Hub.communicate(auth(node, %{action: "receive"}), hub)
  defp advance(clock, n), do: Agent.update(clock, &%{mono: &1.mono + n, wall: &1.wall + n})
end
