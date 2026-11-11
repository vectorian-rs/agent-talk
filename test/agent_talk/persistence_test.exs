defmodule AgentTalk.PersistenceTest do
  use ExUnit.Case, async: true

  alias AgentTalk.Hub
  @moduletag :tmp_dir
  @missing "node is not registered or has expired; join again with role and ring_token"

  setup %{tmp_dir: dir} do
    clock = start_supervised!({Agent, fn -> %{mono: 0, wall: 1_800_000_000_000} end})

    opts = [
      name: nil,
      ttl_ms: 1000,
      membership_file: Path.join(dir, "private/memberships.json"),
      clock: fn -> Agent.get(clock, & &1.mono) end,
      wall_clock: fn -> Agent.get(clock, & &1.wall) end
    ]

    hub = start_hub(opts)
    %{hub: hub, clock: clock, opts: opts, membership_file: opts[:membership_file]}
  end

  test "restart preserves credentials, labels, invitations and IDs, with messages in memory only",
       %{hub: hub, opts: opts, membership_file: file} do
    pm = register(hub, %{role: "pm", project: "hiko", name: "hiko / pm"})

    worker =
      register(hub, %{
        role: "worker",
        ring_token: pm.ring_token,
        project: "hiko",
        name: "hiko / w-1"
      })

    assert {:ok, _} = send_message(hub, pm, worker, "Volatile task")
    contents = File.read!(file)
    refute String.contains?(contents, "Volatile task")
    refute String.contains?(contents, "inbox")
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert Path.wildcard(file <> ".*.tmp") == []

    hub = restart(opts)
    renewed = register(hub, Map.take(worker, [:node_id, :role, :token]))
    same_credentials = renewed.token == worker.token and renewed.ring_token == worker.ring_token
    assert same_credentials, "restart must preserve both credentials"
    assert renewed.node_id == worker.node_id
    assert renewed.name == "hiko / w-1"
    assert renewed.project == "hiko"
    assert {:ok, %{nodes: nodes, inbox: %{pending_messages: 0}}} = Hub.list_nodes(auth(pm), hub)
    assert Enum.sort(Enum.map(nodes, & &1.node_id)) == Enum.sort([pm.node_id, worker.node_id])
    assert {:ok, %{messages: []}} = Hub.snapshot(hub)

    assert {:error, :invalid_token, "invalid node token"} =
             Hub.list_nodes(%{node_id: worker.node_id, token: "incorrect"}, hub)

    newcomer = register(hub, %{role: "worker", ring_token: pm.ring_token})
    assert newcomer.ring_id == pm.ring_id
    assert newcomer.node_id not in [pm.node_id, worker.node_id]
    assert {:ok, _} = send_message(hub, pm, worker, "New task")
    assert {:ok, %{messages: [%{message: "New task"}]}} = receive_messages(hub, worker)
  end

  test "downtime counts toward expiry without losing the ring invitation or reusing IDs", %{
    hub: hub,
    clock: clock,
    opts: opts
  } do
    pm = register(hub, %{role: "pm"})
    old_worker = register(hub, %{role: "worker", ring_token: pm.ring_token})
    stop_supervised!(:persistent_hub)
    Agent.update(clock, &%{&1 | mono: -5000, wall: &1.wall + 1000})
    hub = start_hub(opts)
    assert {:ok, %{nodes: []}} = Hub.snapshot(hub)
    assert {:error, :expired, @missing} = Hub.list_nodes(auth(pm), hub)
    worker = register(hub, %{role: "worker", ring_token: pm.ring_token})
    assert worker.ring_id == pm.ring_id
    assert number(worker.node_id) > number(old_worker.node_id)
    assert {:error, :expired, @missing} = Hub.list_nodes(auth(old_worker), hub)
    stop_supervised!(:persistent_hub)
    advance(clock, 1000)
    hub = start_hub(opts)
    next_pm = register(hub, %{role: "pm"})
    assert number(next_pm.ring_id) > number(worker.node_id)
  end

  test "heartbeats persist lease activity and restart preserves the remaining lease", %{
    hub: hub,
    clock: clock,
    opts: opts
  } do
    pm = register(hub, %{role: "pm"})
    advance(clock, 900)
    assert {:ok, _} = Hub.list_nodes(auth(pm), hub)
    stop_supervised!(:persistent_hub)
    advance(clock, 999)
    hub = start_hub(opts)
    assert {:ok, %{nodes: [%{node_id: id}]}} = Hub.snapshot(hub)
    assert id == pm.node_id
    advance(clock, 1)
    assert {:ok, %{nodes: []}} = Hub.snapshot(hub)
  end

  test "corrupt or unsupported files fail startup instead of silently replacing identities", %{
    opts: opts,
    membership_file: file
  } do
    stop_supervised!(:persistent_hub)

    for contents <- [
          "invalid JSON",
          ~s({"version":2}),
          ~s({"version":1,"next_id":0,"rings":{},"nodes":[{}]})
        ] do
      File.write!(file, contents)
      assert {:error, _} = start_supervised(Supervisor.child_spec({Hub, opts}, id: :invalid_hub))
      assert File.read!(file) == contents
    end
  end

  test "failed writes acknowledge no registration, delivery or credential change", %{
    hub: hub,
    membership_file: file
  } do
    pm = register(hub, %{role: "pm"})
    worker = register(hub, %{role: "worker", ring_token: pm.ring_token})
    saved = file <> ".saved"
    File.rename!(file, saved)
    File.mkdir!(file)
    error = "membership storage unavailable; check the server's membership_file"

    assert {:error, :storage, ^error} = Hub.register(%{role: "pm"}, hub)

    assert {:error, :storage, ^error} =
             Hub.communicate(
               auth(pm, %{action: "send", to: [worker.node_id], message: "Lost?"}),
               hub
             )

    File.rmdir!(file)
    File.rename!(saved, file)
    assert {:ok, %{nodes: nodes}} = Hub.snapshot(hub)
    assert length(nodes) == 2
    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
    assert Path.wildcard(file <> ".*.tmp") == []
    assert {:ok, _} = Hub.list_nodes(auth(pm), hub)
  end

  describe "inbox recovery from the archive" do
    setup %{opts: opts, tmp_dir: dir} do
      stop_supervised!(:persistent_hub)
      opts = opts ++ [history_file: Path.join(dir, "history.sqlite3")]
      %{opts: opts, hub: start_hub(opts)}
    end

    test "queued mail survives a restart, in FIFO order and the live payload shape, exactly once",
         %{hub: hub, opts: opts} do
      pm = register(hub, %{role: "pm"})
      worker = register(hub, %{role: "worker", ring_token: pm.ring_token})
      assert {:ok, %{message_id: first}} = send_message(hub, pm, worker, "First")
      assert {:ok, %{message_id: second}} = send_message(hub, pm, worker, "Second")

      hub = restart(opts)

      assert {:ok, %{inbox: %{pending_messages: 2, next_message_id: ^first}}} =
               Hub.list_nodes(auth(worker), hub)

      assert {:ok, %{messages: [restored, %{id: ^second}]}} = receive_messages(hub, worker)
      assert %{id: ^first, message: "First"} = restored
      assert restored.from == pm.node_id

      assert Enum.sort(Map.keys(restored)) == [:from, :id, :message, :ring_id, :sent_at],
             "recovered copies must match the live inbox payload shape"

      assert {:ok, %{messages: []}} = receive_messages(hub, worker)
      hub = restart(opts)
      assert {:ok, %{messages: []}} = receive_messages(hub, worker)
    end

    test "expired mail is not resurrected for a rejoined identity", %{
      hub: hub,
      opts: opts,
      clock: clock
    } do
      pm = register(hub, %{role: "pm"})
      worker = register(hub, %{role: "worker", ring_token: pm.ring_token})
      assert {:ok, _} = send_message(hub, pm, worker, "Doomed")
      advance(clock, 1001)

      hub = restart(opts)
      assert {:ok, %{nodes: []}} = Hub.snapshot(hub)
      rejoined = register(hub, %{role: "worker", ring_token: pm.ring_token})
      assert rejoined.node_id != worker.node_id
      assert {:ok, %{messages: []}} = receive_messages(hub, rejoined)
    end

    test "recovery is not bounded by the live history window", %{opts: opts} do
      stop_supervised!(:persistent_hub)
      opts = Keyword.put(opts, :history_limit, 3)
      hub = start_hub(opts)
      pm = register(hub, %{role: "pm"})
      slow = register(hub, %{role: "worker", ring_token: pm.ring_token})
      busy = register(hub, %{role: "worker", ring_token: pm.ring_token})
      assert {:ok, _} = send_message(hub, pm, slow, "Assignment")
      for n <- 1..4, do: {:ok, _} = send_message(hub, pm, busy, "Noise #{n}")
      other_pm = register(hub, %{role: "pm"})
      other = register(hub, %{role: "worker", ring_token: other_pm.ring_token})
      assert {:ok, _} = send_message(hub, other_pm, other, "Other ring")

      hub = restart(opts)
      assert {:ok, %{messages: window}} = Hub.snapshot(hub)
      assert length(window) == 3

      refute Enum.any?(window, &(&1.message == "Assignment")),
             "recovery must not insert older pending events into the operator window"

      assert {:ok, %{messages: [%{message: "Assignment"}]}} = receive_messages(hub, slow)
      assert {:ok, %{messages: noise}} = receive_messages(hub, busy)
      assert Enum.map(noise, & &1.message) == for(n <- 1..4, do: "Noise #{n}")
      assert {:ok, %{messages: [%{message: "Other ring"}]}} = receive_messages(hub, other)
    end

    test "a saved backlog larger than max_inbox restores fully", %{hub: hub, opts: opts} do
      pm = register(hub, %{role: "pm"})
      worker = register(hub, %{role: "worker", ring_token: pm.ring_token})
      for n <- 1..3, do: {:ok, _} = send_message(hub, pm, worker, "Backlog #{n}")

      hub = restart(opts ++ [max_inbox: 2])
      assert {:ok, %{inbox: %{pending_messages: 3}}} = Hub.list_nodes(auth(worker), hub)
      assert {:ok, %{messages: [_, _, _]}} = receive_messages(hub, worker)
    end

    test "fan-out recovery is per recipient", %{hub: hub, opts: opts} do
      pm = register(hub, %{role: "pm"})
      prompt = register(hub, %{role: "worker", ring_token: pm.ring_token})
      tardy = register(hub, %{role: "worker", ring_token: pm.ring_token})

      assert {:ok, _} =
               Hub.communicate(
                 auth(pm, %{
                   action: "send",
                   to: [prompt.node_id, tardy.node_id],
                   message: "Fan-out"
                 }),
                 hub
               )

      assert {:ok, %{messages: [_]}} = receive_messages(hub, prompt)

      hub = restart(opts)
      assert {:ok, %{messages: []}} = receive_messages(hub, prompt)
      assert {:ok, %{messages: [%{message: "Fan-out"}]}} = receive_messages(hub, tardy)
    end

    test "a failed pending query stops startup instead of faking empty inboxes", %{
      hub: hub,
      opts: opts
    } do
      stop_supervised!(:persistent_hub)
      opts = Keyword.put(opts, :history_limit, 2)
      hub = start_hub(opts)
      pm = register(hub, %{role: "pm"})
      worker = register(hub, %{role: "worker", ring_token: pm.ring_token})
      assert {:ok, _} = send_message(hub, pm, worker, "Valid 1")
      assert {:ok, _} = send_message(hub, pm, worker, "Valid 2")
      stop_supervised!(:persistent_hub)

      # A malformed archived event addressed to a live node, placed below the
      # live window so only the pending query decodes it.
      {:ok, db} = Exqlite.Sqlite3.open(opts[:history_file])

      :ok =
        Exqlite.Sqlite3.execute(
          db,
          "INSERT INTO messages(sequence, message_id, ring_id, sent_date, event_json) " <>
            "VALUES (0, 'message-x', 'ring-x', '2027-01-01', '{\"to\":[\"#{worker.node_id}\"]}')"
        )

      :ok = Exqlite.Sqlite3.close(db)

      assert {:error, _} = start_supervised(Supervisor.child_spec({Hub, opts}, id: :invalid_hub))
    end
  end

  defp start_hub(opts),
    do: start_supervised!(Supervisor.child_spec({Hub, opts}, id: :persistent_hub))

  defp restart(opts) do
    stop_supervised!(:persistent_hub)
    start_hub(opts)
  end

  defp advance(clock, milliseconds),
    do: Agent.update(clock, &%{mono: &1.mono + milliseconds, wall: &1.wall + milliseconds})

  defp number(id), do: id |> String.split("-") |> List.last() |> String.to_integer()
  defp auth(node, args \\ %{}), do: Map.merge(%{node_id: node.node_id, token: node.token}, args)

  defp register(hub, args) do
    {:ok, node} = Hub.register(args, hub)
    node
  end

  defp send_message(hub, sender, recipient, message),
    do:
      Hub.communicate(
        auth(sender, %{action: "send", to: [recipient.node_id], message: message}),
        hub
      )

  defp receive_messages(hub, node),
    do: Hub.communicate(auth(node, %{action: "receive"}), hub)
end
