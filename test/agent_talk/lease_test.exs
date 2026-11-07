defmodule AgentTalk.LeaseTest do
  use ExUnit.Case, async: true

  alias AgentTalk.Hub
  @missing "node is not registered or has expired; join again with role and ring_token"

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    hub =
      start_supervised!({Hub, name: nil, ttl_ms: 1000, clock: fn -> Agent.get(clock, & &1) end})

    %{hub: hub, clock: clock, pm: register(hub, %{role: "pm"})}
  end

  test "configured TTL applies to creation, renewal and rejoining an existing ring", %{
    clock: clock
  } do
    for ttl_ms <- [86_400_000, 3_600_000] do
      at(clock, 0)

      hub =
        start_supervised!(
          Supervisor.child_spec(
            {Hub, name: nil, ttl_ms: ttl_ms, clock: fn -> Agent.get(clock, & &1) end},
            id: {:ttl, ttl_ms}
          )
        )

      node = register(hub, %{role: "pm"})
      assert node.expires_in_seconds == ttl_ms / 1000
      at(clock, ttl_ms - 1)
      renewed = renew(hub, node)
      same_credentials = renewed.token == node.token and renewed.ring_token == node.ring_token
      assert same_credentials, "active renewal must preserve both credentials"
      assert renewed.node_id == node.node_id
      assert renewed.expires_in_seconds == ttl_ms / 1000
      at(clock, 2 * ttl_ms - 2)
      assert present?(hub, node.node_id)
      at(clock, 2 * ttl_ms - 1)
      refute present?(hub, node.node_id)
      assert registration_error(Hub.register(node, hub)) == @missing
      fresh = register(hub, %{role: node.role, ring_token: node.ring_token})
      assert fresh.node_id != node.node_id
      assert fresh.ring_id == node.ring_id
      assert fresh.expires_in_seconds == ttl_ms / 1000
    end
  end

  test "renewal before expiry preserves the inbox", %{hub: hub, clock: clock, pm: pm} do
    worker = join(hub, pm)
    send_message(hub, pm, [worker.node_id], "Task")
    at(clock, 999)
    renewed = renew(hub, worker)
    assert renewed.pending_messages == 1
    at(clock, 1000)
    assert {:ok, %{messages: [%{message: "Task"}]}} = receive_messages(hub, renewed)
  end

  test "expiry loses the inbox and requires a new ID in the same ring", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    worker = join(hub, pm)
    send_message(hub, pm, [worker.node_id], "Uncollected")
    at(clock, 1000)
    assert {:error, @missing} = receive_messages(hub, worker)
    assert registration_error(Hub.register(worker, hub)) == @missing
    fresh = join(hub, pm)
    assert fresh.node_id != worker.node_id
    assert fresh.ring_id == worker.ring_id
    fresh_credentials = fresh.token != worker.token
    assert fresh_credentials, "fresh identity needs its own private token"
    assert {:ok, %{messages: []}} = receive_messages(hub, fresh)
    assert {:error, @missing} = receive_messages(hub, worker)
    assert {:error, "invalid node token"} = receive_messages(hub, %{fresh | token: worker.token})
  end

  test "a lost node token cannot reclaim an active ID; an invitation only creates another identity",
       %{hub: hub, pm: pm} do
    worker = join(hub, pm)
    lost = %{worker | token: "lost-token"}
    assert registration_error(Hub.register(lost, hub)) == "invalid node token"
    fresh = join(hub, pm)
    assert fresh.node_id != worker.node_id
    assert fresh.ring_id == worker.ring_id
    assert present?(hub, worker.node_id)
    assert {:error, "invalid node token"} = receive_messages(hub, %{worker | token: fresh.token})
  end

  test "invalid credentials do not extend a registration", %{hub: hub, clock: clock, pm: pm} do
    worker = join(hub, pm)
    at(clock, 999)
    stale = %{worker | token: "incorrect-token"}
    assert {:error, "invalid node token"} = receive_messages(hub, stale)
    assert registration_error(Hub.register(stale, hub)) == "invalid node token"
    assert {:error, "invalid node token"} = Hub.list_nodes(auth(stale), hub)
    at(clock, 1000)
    refute present?(hub, worker.node_id)
  end

  for action <- ["send", "receive", "list"] do
    test "authenticated #{action} extends only the caller's lease", %{
      hub: hub,
      clock: clock,
      pm: pm
    } do
      worker = join(hub, pm)
      at(clock, 900)

      result =
        case unquote(action) do
          "send" -> send_message(hub, pm, [worker.node_id], "Task")
          "receive" -> receive_messages(hub, pm)
          "list" -> Hub.list_nodes(auth(pm), hub)
        end

      assert {:ok, _} = result
      at(clock, 1000)
      assert present?(hub, pm.node_id)
      refute present?(hub, worker.node_id)
      at(clock, 1899)
      assert present?(hub, pm.node_id)
      at(clock, 1900)
      refute present?(hub, pm.node_id)
    end
  end

  test "an authenticated send failure still renews the caller", %{hub: hub, clock: clock, pm: pm} do
    at(clock, 900)

    assert {:error, "unknown or expired recipients: missing"} =
             send_message(hub, pm, ["missing"], "Task")

    at(clock, 1000)
    assert present?(hub, pm.node_id)
  end

  test "a successful send immediately before recipient expiry can lose its queued message", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    worker = join(hub, pm)
    at(clock, 999)

    assert {:ok, %{delivered_to: [recipient], message_id: id}} =
             send_message(hub, pm, [worker.node_id], "Task")

    assert recipient == worker.node_id
    at(clock, 1000)
    refute present?(hub, worker.node_id)
    assert {:error, _} = send_message(hub, pm, [worker.node_id], "Too late")
    fresh = join(hub, pm)
    assert {:ok, %{messages: []}} = receive_messages(hub, fresh)
    assert {:ok, %{messages: [%{id: ^id, received_by: []}]}} = Hub.snapshot(hub)
  end

  test "fan-out at a recipient's exact expiry never partially delivers", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    first = join(hub, pm)
    second = join(hub, pm)
    at(clock, 900)
    second = renew(hub, second)
    pm = renew(hub, pm)
    at(clock, 1000)
    assert {:error, _} = send_message(hub, pm, [first.node_id, second.node_id], "Task")
    assert {:ok, %{messages: []}} = receive_messages(hub, second)
    assert {:ok, %{messages: []}} = Hub.snapshot(hub)
  end

  test "concurrent active renewals preserve one identity; expired credentials never renew", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    worker = join(hub, pm)
    at(clock, 999)
    results = concurrent(fn -> Hub.register(worker, hub) end)
    successful = for {:ok, node} <- results, do: node
    assert length(successful) == 8

    same_identity =
      Enum.all?(successful, &(&1.token == worker.token and &1.node_id == worker.node_id))

    assert same_identity, "concurrent renewal must preserve credentials and ID"
    at(clock, 1999)
    results = concurrent(fn -> registration_error(Hub.register(worker, hub)) end)
    assert results == List.duplicate(@missing, 8)
    refute present?(hub, worker.node_id)
  end

  test "concurrent receives drain a batch once", %{hub: hub, pm: pm} do
    worker = join(hub, pm)
    send_message(hub, pm, [worker.node_id], "First")
    send_message(hub, pm, [worker.node_id], "Second")
    batches = concurrent(fn -> receive_messages(hub, worker) end)
    assert Enum.count(batches, &match?({:ok, %{messages: []}}, &1)) == 7
    messages = for {:ok, %{messages: messages}} <- batches, message <- messages, do: message
    assert Enum.map(messages, & &1.message) == ["First", "Second"]
  end

  test "concurrent broadcasts have the same FIFO order in every inbox", %{hub: hub, pm: pm} do
    workers = [join(hub, pm), join(hub, pm)]
    recipients = Enum.map(workers, & &1.node_id)
    results = concurrent(fn -> send_message(hub, pm, recipients, "Task") end)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    batches =
      Enum.map(workers, fn worker ->
        {:ok, %{messages: messages}} = receive_messages(hub, worker)
        Enum.map(messages, & &1.id)
      end)

    assert length(hd(batches)) == 8
    assert length(Enum.uniq(batches)) == 1
  end

  defp concurrent(fun),
    do: 1..8 |> Enum.map(fn _ -> Task.async(fun) end) |> Enum.map(&Task.await/1)

  defp at(clock, time), do: Agent.update(clock, fn _ -> time end)

  defp register(hub, args) do
    {:ok, node} = Hub.register(args, hub)
    node
  end

  defp join(hub, pm), do: register(hub, %{role: "worker", ring_token: pm.ring_token})
  defp renew(hub, node), do: register(hub, Map.take(node, [:role, :node_id, :token]))
  defp registration_error({:error, reason}), do: reason
  defp registration_error({:ok, _}), do: :unexpected_success

  defp present?(hub, id) do
    {:ok, %{nodes: nodes}} = Hub.snapshot(hub)
    Enum.any?(nodes, &(&1.node_id == id))
  end

  defp auth(node, fields \\ %{}),
    do: Map.merge(%{node_id: node.node_id, token: node.token}, fields)

  defp send_message(hub, node, recipients, message),
    do: Hub.communicate(auth(node, %{action: "send", to: recipients, message: message}), hub)

  defp receive_messages(hub, node), do: Hub.communicate(auth(node, %{action: "receive"}), hub)
end
