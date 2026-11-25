defmodule AgentTalk.LeaseTest do
  use ExUnit.Case, async: true

  alias AgentTalk.Hub

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    hub =
      start_supervised!(
        {Hub, name: nil, presence_timeout_ms: 1000, clock: fn -> Agent.get(clock, & &1) end}
      )

    %{hub: hub, clock: clock, pm: register(hub, %{role: "pm"})}
  end

  test "presence timeout does not expire membership or change credentials", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    assert pm.expires_in_seconds == nil
    assert pm.presence_timeout_seconds == 1
    assert member(hub, pm).online
    at(clock, 999)
    assert member(hub, pm).online
    at(clock, 1000)
    refute member(hub, pm).online
    at(clock, 30 * 86_400_000)
    renewed = renew(hub, pm)
    assert renewed.node_id == pm.node_id
    same_credentials = renewed.token == pm.token and renewed.ring_token == pm.ring_token
    assert same_credentials, "renewal must preserve both credentials"
    assert renewed.online
    assert renewed.expires_in_seconds == nil
  end

  test "offline members retain queued mail and can receive with the original identity", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    worker = join(hub, pm)
    send_message(hub, pm, [worker.node_id], "Before offline")
    at(clock, 1000)
    assert member(hub, worker).pending_messages == 1
    refute member(hub, worker).online
    assert {:ok, _} = send_message(hub, pm, [worker.node_id], "While offline")
    refute member(hub, worker).online, "incoming traffic does not prove recipient presence"
    at(clock, 86_400_000)
    assert {:ok, %{messages: messages}} = receive_messages(hub, worker)
    assert Enum.map(messages, & &1.message) == ["Before offline", "While offline"]
    assert member(hub, worker).online
  end

  test "invalid credentials neither remove membership nor update presence", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    worker = join(hub, pm)
    at(clock, 1000)
    assert {:error, :invalid_token, _} = Hub.list_nodes(auth(%{worker | token: "incorrect"}), hub)
    refute member(hub, worker).online
    assert member(hub, worker).node_id == worker.node_id
    assert {:ok, _} = Hub.list_nodes(auth(worker), hub)
    assert member(hub, worker).online
  end

  for action <- ["send", "receive", "list"] do
    test "authenticated #{action} updates only the caller's presence", %{
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
      assert member(hub, pm).online
      refute member(hub, worker).online
      at(clock, 1900)
      refute member(hub, pm).online
      assert member(hub, worker).node_id == worker.node_id
    end
  end

  test "continuous communication preserves presence over many timeout intervals", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    for tick <- 1..100 do
      at(clock, tick * 900)
      assert {:ok, _} = Hub.list_nodes(auth(pm), hub)
      assert member(hub, pm).online
    end

    assert renew(hub, pm).node_id == pm.node_id
  end

  test "explicit eviction, unlike inactivity, invalidates credentials and discards the inbox", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    worker = join(hub, pm)
    send_message(hub, pm, [worker.node_id], "Queued")
    at(clock, 100_000)
    assert {:ok, %{evicted: true}} = Hub.evict(worker.node_id, hub)
    assert {:error, :not_registered, _} = receive_messages(hub, worker)
    assert {:error, :not_registered, _} = Hub.register(worker, hub)
    replacement = join(hub, pm)
    assert replacement.node_id != worker.node_id
    assert {:ok, %{messages: []}} = receive_messages(hub, replacement)

    assert {:error, :invalid_token, _} =
             receive_messages(hub, %{replacement | token: worker.token})
  end

  test "fan-out reaches online and offline members without dropping accepted mail", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    first = join(hub, pm)
    second = join(hub, pm)
    at(clock, 900)
    renew(hub, second)
    at(clock, 1000)
    refute member(hub, first).online
    assert member(hub, second).online
    assert {:ok, _} = send_message(hub, pm, [first.node_id, second.node_id], "Task")

    for worker <- [first, second] do
      assert {:ok, %{messages: [%{message: "Task"}]}} = receive_messages(hub, worker)
    end
  end

  test "concurrent returns after a long offline period preserve one identity", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    worker = join(hub, pm)
    at(clock, 30 * 86_400_000)
    results = concurrent(fn -> renew(hub, worker) end)

    same_identity =
      Enum.all?(results, &(&1.node_id == worker.node_id and &1.token == worker.token))

    assert same_identity, "every return must preserve the identity and token"
    assert member(hub, worker).online
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

  test "concurrent broadcasts keep the same FIFO order in every inbox", %{hub: hub, pm: pm} do
    workers = [join(hub, pm), join(hub, pm)]
    recipients = Enum.map(workers, & &1.node_id)

    assert Enum.all?(
             concurrent(fn -> send_message(hub, pm, recipients, "Task") end),
             &match?({:ok, _}, &1)
           )

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

  defp member(hub, node) do
    {:ok, %{nodes: nodes}} = Hub.snapshot(hub)
    Enum.find(nodes, &(&1.node_id == node.node_id))
  end

  defp join(hub, pm), do: register(hub, %{role: "worker", ring_token: pm.ring_token})
  defp renew(hub, node), do: register(hub, Map.take(node, [:role, :node_id, :token]))

  defp auth(node, fields \\ %{}),
    do: Map.merge(%{node_id: node.node_id, token: node.token}, fields)

  defp send_message(hub, node, recipients, message),
    do: Hub.communicate(auth(node, %{action: "send", to: recipients, message: message}), hub)

  defp receive_messages(hub, node), do: Hub.communicate(auth(node, %{action: "receive"}), hub)
end
