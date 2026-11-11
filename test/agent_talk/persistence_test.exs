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
