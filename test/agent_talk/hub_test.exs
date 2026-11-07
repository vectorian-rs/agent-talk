defmodule AgentTalk.HubTest do
  use ExUnit.Case, async: true

  alias AgentTalk.Hub

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    hub =
      start_supervised!(
        {Hub, name: nil, ttl_ms: 1000, max_inbox: 2, clock: fn -> Agent.get(clock, & &1) end}
      )

    %{hub: hub, clock: clock}
  end

  test "registration, discovery and renewal preserve a private inbox", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "backend")
    assert {:ok, _} = send_message(hub, pm, %{to: ["backend"], message: "Build the API"})

    assert {:ok, %{nodes: [node]}} = Hub.list_nodes("implementation", hub)
    assert node.node_id == "backend"
    assert node.pending_messages == 1
    refute Map.has_key?(node, :token)

    assert {:error, _} = Hub.register(%{node_id: "backend", role: "implementation"}, hub)

    assert {:ok, renewed} =
             Hub.register(%{node_id: "backend", role: "implementation", token: worker.token}, hub)

    assert renewed.token == worker.token
    assert {:ok, %{messages: [%{message: "Build the API"}]}} = receive_messages(hub, worker)
    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
  end

  test "a PM broadcasts to N workers and workers reply privately", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    backend = register(hub, "backend")
    frontend = register(hub, "frontend")

    assert {:ok, %{delivered_to: ["backend", "frontend"], message_id: id}} =
             send_message(hub, pm, %{to_role: "implementation", message: "Start sprint"})

    for worker <- [backend, frontend] do
      assert {:ok, %{messages: [%{id: ^id, from: "pm", message: "Start sprint"}]}} =
               receive_messages(hub, worker)
    end

    assert {:ok, %{messages: []}} = receive_messages(hub, pm)
    assert {:ok, _} = send_message(hub, backend, %{to: ["pm"], message: "API ready"})

    assert {:ok, %{messages: [%{from: "backend", message: "API ready"}]}} =
             receive_messages(hub, pm)

    assert {:ok, %{messages: []}} = receive_messages(hub, frontend)
  end

  test "explicit fan-out deduplicates recipients and preserves FIFO order", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")

    assert {:ok, %{delivered_to: ["worker"]}} =
             send_message(hub, pm, %{to: ["worker", "worker"], message: "First"})

    assert {:ok, _} = send_message(hub, pm, %{to: ["worker"], message: "Second"})
    assert {:ok, %{messages: messages}} = receive_messages(hub, worker)
    assert Enum.map(messages, & &1.message) == ["First", "Second"]
  end

  test "failed fan-out never partially delivers", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")

    assert {:error, _} = send_message(hub, pm, %{to: ["worker", "missing"], message: "Task"})
    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
  end

  test "inbox capacity rejects the whole broadcast", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    other = register(hub, "other")

    for text <- ["One", "Two"] do
      assert {:ok, _} = send_message(hub, pm, %{to: ["worker"], message: text})
    end

    assert {:error, _} = send_message(hub, pm, %{to_role: "implementation", message: "Three"})
    assert {:ok, %{messages: []}} = receive_messages(hub, other)
    assert {:ok, %{messages: [_, _]}} = receive_messages(hub, worker)
  end

  test "tokens prevent impersonation and reading another inbox", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    assert {:ok, _} = send_message(hub, pm, %{to: ["worker"], message: "Private"})

    assert {:error, "invalid node token"} =
             Hub.communicate(%{action: "receive", node_id: "worker", token: pm.token}, hub)

    assert {:error, "invalid node token"} =
             send_message(hub, %{pm | token: worker.token}, %{to: ["worker"], message: "Fake"})

    assert {:ok, %{messages: [%{message: "Private"}]}} = receive_messages(hub, worker)
  end

  test "only active nodes are listed and authenticated activity renews the lease", %{
    hub: hub,
    clock: clock
  } do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    Agent.update(clock, fn _ -> 600 end)
    assert {:ok, _} = receive_messages(hub, worker)
    Agent.update(clock, fn _ -> 1000 end)

    assert {:ok, %{nodes: [%{node_id: "worker"}]}} = Hub.list_nodes(nil, hub)
    assert {:error, _} = receive_messages(hub, pm)

    Agent.update(clock, fn _ -> 1600 end)
    assert {:ok, %{nodes: []}} = Hub.list_nodes(nil, hub)
    assert {:error, _} = receive_messages(hub, worker)
    assert register(hub, "worker").token != worker.token
  end

  test "invalid targeting and empty messages do not deliver", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")

    for fields <- [
          %{to: [], message: "Task"},
          %{to: ["worker"], to_role: "implementation", message: "Task"},
          %{message: "Task"},
          %{to: ["worker"], message: "  "},
          %{to: ["worker"]},
          %{to: ["worker"], message: String.duplicate("a", 65_537)}
        ] do
      assert {:error, _} = send_message(hub, pm, fields)
    end

    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
  end

  test "broadcast to all excludes the sender", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    register(hub, "worker")

    assert {:ok, %{delivered_to: ["worker"]}} =
             send_message(hub, pm, %{to_role: "all", message: "Hi"})

    assert {:ok, %{messages: []}} = receive_messages(hub, pm)
  end

  test "operator snapshots observe routes without consuming inboxes or exposing tokens", %{
    hub: hub
  } do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")
    assert {:ok, %{message_id: id}} = send_message(hub, pm, %{to: ["worker"], message: "Task"})

    assert {:ok, %{nodes: nodes, messages: [event]}} = Hub.snapshot(hub)
    assert Enum.all?(nodes, &(not Map.has_key?(&1, :token)))
    assert event.id == id
    assert event.from == "pm"
    assert event.to == ["worker"]
    assert event.received_by == []
    refute Map.has_key?(event, :token)
    assert {:ok, %{messages: [%{id: ^id}]}} = receive_messages(hub, worker)
    assert {:ok, %{messages: [%{received_by: ["worker"]}]}} = Hub.snapshot(hub)
  end

  test "operator history retains exactly the newest 50 messages after inboxes are drained", %{
    hub: hub
  } do
    pm = register(hub, "pm", "pm")
    worker = register(hub, "worker")

    for number <- 1..55 do
      assert {:ok, _} = send_message(hub, pm, %{to: ["worker"], message: "Message #{number}"})
      assert {:ok, _} = receive_messages(hub, worker)
    end

    assert {:ok, %{messages: history}} = Hub.snapshot(hub)
    assert length(history) == 50
    assert hd(history).message == "Message 55"
    assert List.last(history).message == "Message 6"
    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
    assert {:error, _} = send_message(hub, pm, %{to: ["missing"], message: "Failed"})
    assert {:ok, %{messages: ^history}} = Hub.snapshot(hub)
  end

  test "operator delivery status tracks recipients independently", %{hub: hub} do
    pm = register(hub, "pm", "pm")
    backend = register(hub, "backend")
    frontend = register(hub, "frontend")
    assert {:ok, _} = send_message(hub, pm, %{to_role: "implementation", message: "Start"})
    receive_messages(hub, backend)
    assert {:ok, %{messages: [%{received_by: ["backend"]}]}} = Hub.snapshot(hub)
    receive_messages(hub, frontend)
    assert {:ok, %{messages: [%{received_by: recipients}]}} = Hub.snapshot(hub)
    assert Enum.sort(recipients) == ["backend", "frontend"]
  end

  test "configured history limit trims the log without truncating the inbox" do
    hub =
      start_supervised!(
        Supervisor.child_spec({Hub, name: nil, history_limit: 2}, id: :limited_history)
      )

    pm = register(hub, "limited-pm", "pm")
    worker = register(hub, "limited-worker")

    for number <- 1..4 do
      assert {:ok, _} =
               send_message(hub, pm, %{to: [worker.node_id], message: "Message #{number}"})
    end

    assert {:ok, %{messages: history, history_limit: 2}} = Hub.snapshot(hub)
    assert Enum.map(history, & &1.message) == ["Message 4", "Message 3"]
    assert {:ok, %{messages: inbox}} = receive_messages(hub, worker)
    assert Enum.map(inbox, & &1.message) == Enum.map(1..4, &"Message #{&1}")
  end

  test "presence sweeps publish expiry without an incoming tool call", %{clock: clock} do
    pubsub = start_supervised!({Phoenix.PubSub, name: AgentTalk.HubTestPubSub})
    assert is_pid(pubsub)
    Phoenix.PubSub.subscribe(AgentTalk.HubTestPubSub, Hub.topic())

    hub =
      start_supervised!(
        Supervisor.child_spec(
          {Hub,
           name: nil,
           ttl_ms: 1000,
           clock: fn -> Agent.get(clock, & &1) end,
           pubsub: AgentTalk.HubTestPubSub},
          id: :observed_hub
        )
      )

    register(hub, "worker")
    assert_receive :hub_updated
    Agent.update(clock, fn _ -> 1000 end)
    send(hub, :sweep)
    assert_receive :hub_updated
    assert {:ok, %{nodes: []}} = Hub.snapshot(hub)
  end

  defp register(hub, id, role \\ "implementation") do
    {:ok, node} = Hub.register(%{node_id: id, role: role}, hub)
    node
  end

  defp send_message(hub, node, fields) do
    args = Map.merge(%{action: "send", node_id: node.node_id, token: node.token}, fields)
    Hub.communicate(args, hub)
  end

  defp receive_messages(hub, node) do
    Hub.communicate(%{action: "receive", node_id: node.node_id, token: node.token}, hub)
  end
end
