defmodule AgentTalk.LeaseTest do
  use ExUnit.Case, async: true

  alias AgentTalk.Hub

  @missing "node is not registered or has expired; call register_node"
  @owned "node_id is already registered; its token is required to renew it"

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    hub =
      start_supervised!({Hub, name: nil, ttl_ms: 1000, clock: fn -> Agent.get(clock, & &1) end})

    %{hub: hub, clock: clock}
  end

  test "configured TTL applies to initial registration, renewal and re-registration", %{
    clock: clock
  } do
    for ttl_ms <- [86_400_000, 3_600_000] do
      Agent.update(clock, fn _ -> 0 end)

      hub =
        start_supervised!(
          Supervisor.child_spec(
            {Hub, name: nil, ttl_ms: ttl_ms, clock: fn -> Agent.get(clock, & &1) end},
            id: {:configured_ttl, ttl_ms}
          )
        )

      node = register(hub, "worker")
      assert node.expires_in_seconds == ttl_ms / 1000
      at(clock, ttl_ms - 1)
      renewed = renew(hub, node)
      same_token = renewed.token == node.token
      assert same_token, "active renewal must preserve the token"
      assert renewed.expires_in_seconds == ttl_ms / 1000

      at(clock, 2 * ttl_ms - 2)
      assert ids(hub) == ["worker"]
      at(clock, 2 * ttl_ms - 1)
      assert ids(hub) == []

      fresh = renew(hub, renewed)
      changed_token = fresh.token != renewed.token
      assert changed_token, "registration at expiry must replace the token"
      assert fresh.expires_in_seconds == ttl_ms / 1000
    end
  end

  test "renewal before expiry preserves queued messages", %{hub: hub, clock: clock} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    assert {:ok, _} = send_message(hub, pm, ["worker"], "Task")
    at(clock, 999)
    renewed = renew(hub, worker)
    assert renewed.pending_messages == 1
    at(clock, 1000)
    assert {:ok, %{messages: [%{message: "Task"}]}} = receive_messages(hub, renewed)
  end

  test "expiry replaces the token, discards the inbox and rejects stale ownership", %{
    hub: hub,
    clock: clock
  } do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    assert {:ok, _} = send_message(hub, pm, ["worker"], "Uncollected")
    at(clock, 1000)
    assert {:error, @missing} = receive_messages(hub, worker)

    fresh = renew(hub, worker)
    changed_token = fresh.token != worker.token
    assert changed_token, "expired ownership must not authorize the new registration"
    assert fresh.pending_messages == 0
    assert {:error, "invalid node token"} = receive_messages(hub, worker)
    assert registration_error(Hub.register(worker, hub)) == @owned

    assert registration_error(Hub.register(%{node_id: "worker", role: "implementation"}, hub)) ==
             @owned

    assert {:ok, %{messages: []}} = receive_messages(hub, fresh)
  end

  test "a lost replacement token can be recovered only after the current lease expires", %{
    hub: hub,
    clock: clock
  } do
    old = register(hub, "worker")
    at(clock, 1000)
    replacement = renew(hub, old)
    at(clock, 1999)
    assert registration_error(Hub.register(old, hub)) == @owned
    assert {:error, "invalid node token"} = receive_messages(hub, old)
    at(clock, 2000)
    recovered = renew(hub, old)
    changed_token = recovered.token != replacement.token
    assert changed_token, "recovery after expiry must create a fresh token"
    assert {:ok, %{messages: []}} = receive_messages(hub, recovered)
  end

  test "invalid credentials do not extend a registration", %{hub: hub, clock: clock} do
    worker = register(hub, "worker")
    at(clock, 999)
    stale = %{worker | token: "incorrect-token"}
    assert {:error, "invalid node token"} = receive_messages(hub, stale)
    assert registration_error(Hub.register(stale, hub)) == @owned
    at(clock, 1000)
    assert ids(hub) == []
  end

  for action <- ["send", "receive"] do
    test "authenticated #{action} extends only the caller's lease", %{hub: hub, clock: clock} do
      pm = register(hub, "pm", "pm")
      register(hub, "worker")
      at(clock, 900)

      result =
        case unquote(action) do
          "send" -> send_message(hub, pm, ["worker"], "Task")
          "receive" -> receive_messages(hub, pm)
        end

      assert {:ok, _} = result
      at(clock, 1000)
      assert ids(hub) == ["pm"]
      at(clock, 1899)
      assert ids(hub) == ["pm"]
      at(clock, 1900)
      assert ids(hub) == []
    end
  end

  test "an authenticated send failure still renews the caller", %{hub: hub, clock: clock} do
    pm = register(hub, "pm", "pm")
    at(clock, 900)

    assert {:error, "unknown or expired recipients: missing"} =
             send_message(hub, pm, ["missing"], "Task")

    at(clock, 1000)
    assert ids(hub) == ["pm"]
  end

  test "queueing immediately before recipient expiry can succeed and then lose the message", %{
    hub: hub,
    clock: clock
  } do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    at(clock, 999)

    assert {:ok, %{delivered_to: ["worker"], message_id: id}} =
             send_message(hub, pm, ["worker"], "Task")

    at(clock, 1000)
    assert ids(hub) == ["pm"]

    assert {:error, "unknown or expired recipients: worker"} =
             send_message(hub, pm, ["worker"], "Too late")

    fresh = renew(hub, worker)
    assert {:ok, %{messages: []}} = receive_messages(hub, fresh)
    assert {:ok, %{messages: [%{id: ^id, received_by: []}]}} = Hub.snapshot(hub)
  end

  test "fan-out at a recipient's exact expiry never partially delivers", %{hub: hub, clock: clock} do
    pm = register(hub, "pm", "pm")
    register(hub, "w-1")
    worker = register(hub, "w-2")
    at(clock, 900)
    worker = renew(hub, worker)
    pm = renew(hub, pm)
    at(clock, 1000)

    assert {:error, "unknown or expired recipients: w-1"} =
             send_message(hub, pm, ["w-1", "w-2"], "Task")

    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
    assert {:ok, %{messages: []}} = Hub.snapshot(hub)
  end

  test "concurrent renewals preserve ownership; concurrent re-registrations have one winner", %{
    hub: hub,
    clock: clock
  } do
    worker = register(hub, "worker")
    at(clock, 999)
    results = concurrent(fn -> Hub.register(worker, hub) end)
    successful = for {:ok, node} <- results, do: node
    assert length(successful) == 8
    same_tokens = Enum.all?(successful, &(&1.token == worker.token))
    assert same_tokens, "concurrent active renewals must keep one token"

    at(clock, 1999)
    results = concurrent(fn -> Hub.register(worker, hub) end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, @owned})) == 7
    [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    changed_token = winner.token != worker.token
    assert changed_token, "only the winning re-registration receives the new token"
    assert {:error, "invalid node token"} = receive_messages(hub, worker)
    assert {:ok, %{messages: []}} = receive_messages(hub, winner)
  end

  test "concurrent receives drain a queued batch only once", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    assert {:ok, _} = send_message(hub, pm, ["worker"], "First")
    assert {:ok, _} = send_message(hub, pm, ["worker"], "Second")
    batches = concurrent(fn -> receive_messages(hub, worker) end)
    assert Enum.count(batches, &match?({:ok, %{messages: []}}, &1)) == 7
    messages = for {:ok, %{messages: messages}} <- batches, message <- messages, do: message
    assert Enum.map(messages, & &1.message) == ["First", "Second"]
  end

  test "concurrent broadcasts have the same FIFO order in every inbox", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    workers = Enum.map(["w-1", "w-2"], &register(hub, &1))
    results = concurrent(fn -> send_message(hub, pm, ["w-1", "w-2"], "Task") end)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    batches =
      Enum.map(workers, fn worker ->
        {:ok, %{messages: messages}} = receive_messages(hub, worker)
        Enum.map(messages, & &1.id)
      end)

    assert length(hd(batches)) == 8
    assert Enum.uniq(batches) |> length() == 1
  end

  defp concurrent(fun) do
    1..8 |> Enum.map(fn _ -> Task.async(fun) end) |> Enum.map(&Task.await/1)
  end

  defp at(clock, time), do: Agent.update(clock, fn _ -> time end)

  defp register(hub, id, role \\ "implementation") do
    {:ok, node} = Hub.register(%{node_id: id, role: role}, hub)
    node
  end

  defp renew(hub, node) do
    {:ok, renewed} = Hub.register(node, hub)
    renewed
  end

  # Never let a failed assertion print a successful registration's private token.
  defp registration_error({:error, reason}), do: reason
  defp registration_error({:ok, _node}), do: :unexpected_success

  defp ids(hub) do
    {:ok, %{nodes: nodes}} = Hub.list_nodes(nil, hub)
    Enum.map(nodes, & &1.node_id)
  end

  defp send_message(hub, node, recipients, message) do
    Hub.communicate(
      %{
        action: "send",
        node_id: node.node_id,
        token: node.token,
        to: recipients,
        message: message
      },
      hub
    )
  end

  defp receive_messages(hub, node) do
    Hub.communicate(%{action: "receive", node_id: node.node_id, token: node.token}, hub)
  end
end
