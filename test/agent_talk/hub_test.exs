defmodule AgentTalk.HubTest do
  use ExUnit.Case, async: true

  alias AgentTalk.Hub

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    hub =
      start_supervised!(
        {Hub, name: nil, ttl_ms: 1000, max_inbox: 2, clock: fn -> Agent.get(clock, & &1) end}
      )

    %{hub: hub, clock: clock, pm: register(hub, %{role: "pm"})}
  end

  test "a PM creates a ring and receives credentials and a reusable onboarding template", %{
    pm: pm
  } do
    assert pm.role == "pm"
    assert is_binary(pm.node_id)
    assert is_binary(pm.ring_id)
    assert pm.expires_in_seconds == 1
    assert pm.onboarding_prompt_template =~ "<ROLE>"
    assert pm.onboarding_prompt_template =~ "<RING_TOKEN>"
    assert pm.instructions =~ "Save this complete response"
    separate_tokens = pm.token != pm.ring_token
    assert separate_tokens, "node credentials and ring invitations must be distinct"
    template_is_safe = not String.contains?(pm.onboarding_prompt_template, pm.token)
    assert template_is_safe, "onboarding must not disclose the PM's private node token"
  end

  test "agents join with arbitrary roles and a ring invitation", %{hub: hub, pm: pm} do
    worker = join(hub, pm)
    reviewer = join(hub, pm, "reviewer")
    assert worker.role == "worker"
    assert reviewer.role == "reviewer"
    assert worker.ring_id == pm.ring_id
    assert reviewer.ring_id == pm.ring_id
    assert length(Enum.uniq([pm.node_id, worker.node_id, reviewer.node_id])) == 3
    same_invitation = worker.ring_token == pm.ring_token
    assert same_invitation, "saveable registration responses must retain the ring invitation"
  end

  test "a joining agent needs a valid invitation and cannot choose its own ID", %{
    hub: hub,
    pm: pm
  } do
    assert {:error, _} = Hub.register(%{role: "worker"}, hub)

    assert {:error, "invalid ring token"} =
             Hub.register(%{role: "worker", ring_token: "invalid"}, hub)

    assert {:error, _} =
             Hub.register(%{role: "worker", ring_token: pm.ring_token, node_id: "chosen-id"}, hub)

    assert {:error, _} = Hub.register(%{role: ""}, hub)
    assert {:error, _} = Hub.register(%{role: "all"}, hub)
    assert {:ok, %{nodes: [_]}} = Hub.snapshot(hub)
  end

  test "authenticated discovery is restricted to the caller's ring", %{hub: hub, pm: pm} do
    worker = join(hub, pm)
    other_pm = register(hub, %{role: "pm"})
    join(hub, other_pm)
    assert {:ok, %{ring_id: ring_id, nodes: nodes}} = Hub.list_nodes(auth(pm), hub)
    assert ring_id == pm.ring_id
    assert Enum.map(nodes, & &1.node_id) |> Enum.sort() == Enum.sort([pm.node_id, worker.node_id])
    assert Enum.all?(nodes, &(not Map.has_key?(&1, :token) and not Map.has_key?(&1, :ring_token)))
    assert {:ok, %{nodes: [found]}} = Hub.list_nodes(auth(pm, %{role: "worker"}), hub)
    assert found.node_id == worker.node_id

    assert {:error, "invalid node token"} =
             Hub.list_nodes(%{node_id: pm.node_id, token: worker.token}, hub)
  end

  test "active renewal preserves ID, tokens, ring and queued messages", %{hub: hub, pm: pm} do
    worker = join(hub, pm)
    assert {:ok, _} = send_message(hub, pm, %{to: [worker.node_id], message: "Task"})
    renewed = register(hub, Map.take(worker, [:role, :node_id, :token]))
    same_credentials = renewed.token == worker.token and renewed.ring_token == worker.ring_token
    assert same_credentials, "renewal must preserve both credentials"
    assert renewed.node_id == worker.node_id
    assert renewed.ring_id == worker.ring_id
    assert {:ok, %{messages: [%{message: "Task"}]}} = receive_messages(hub, renewed)
    assert {:error, "renewal cannot change role"} = Hub.register(%{worker | role: "pm"}, hub)

    assert {:error, "ring_token does not match this node's ring"} =
             Hub.register(%{worker | ring_token: "wrong-ring"}, hub)
  end

  test "inbox notifications do not consume mail and distinguish successive equal-size batches", %{
    hub: hub,
    pm: pm
  } do
    worker = join(hub, pm)

    assert {:ok, %{message_id: first}} =
             send_message(hub, pm, %{to: [worker.node_id], message: "One"})

    for _ <- 1..2 do
      assert {:ok, %{nodes: [], inbox: %{pending_messages: 1, next_message_id: ^first}}} =
               Hub.list_nodes(auth(worker, %{role: "absent"}), hub)
    end

    assert {:ok, %{messages: [%{id: ^first}]}} = receive_messages(hub, worker)

    assert {:ok, %{inbox: %{pending_messages: 0, next_message_id: nil}}} =
             Hub.list_nodes(auth(worker), hub)

    assert {:ok, %{message_id: second}} =
             send_message(hub, pm, %{to: [worker.node_id], message: "Two"})

    refute first == second

    assert {:ok, %{inbox: %{pending_messages: 1, next_message_id: ^second}}} =
             Hub.list_nodes(auth(worker), hub)
  end

  test "ring invitations never authorize another node's messages or discovery", %{
    hub: hub,
    pm: pm
  } do
    worker = join(hub, pm)

    for token <- [pm.ring_token, pm.token] do
      args = %{node_id: worker.node_id, token: token}
      assert {:error, "invalid node token"} = Hub.list_nodes(args, hub)

      assert {:error, "invalid node token"} =
               Hub.communicate(Map.put(args, :action, "receive"), hub)
    end
  end

  test "a PM broadcasts to its workers and receives their private replies", %{hub: hub, pm: pm} do
    workers = [join(hub, pm), join(hub, pm)]

    assert {:ok, %{delivered_to: recipients, message_id: id}} =
             send_message(hub, pm, %{to_role: "worker", message: "Start"})

    assert recipients == Enum.sort(Enum.map(workers, & &1.node_id))

    for worker <- workers do
      assert {:ok, %{messages: [%{id: ^id, from: sender}]}} = receive_messages(hub, worker)
      assert sender == pm.node_id
      assert {:ok, _} = send_message(hub, worker, %{to: [pm.node_id], message: "Ready"})
    end

    assert {:ok, %{messages: replies}} = receive_messages(hub, pm)
    assert Enum.map(replies, & &1.from) |> Enum.sort() == recipients
  end

  test "direct sends and broadcasts cannot cross ring boundaries", %{hub: hub, pm: pm} do
    worker = join(hub, pm)
    other_pm = register(hub, %{role: "pm"})
    outsider = join(hub, other_pm)

    assert {:error, _} =
             send_message(hub, pm, %{to: [worker.node_id, outsider.node_id], message: "Mixed"})

    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
    assert {:ok, %{messages: []}} = receive_messages(hub, outsider)

    assert {:ok, %{delivered_to: [recipient]}} =
             send_message(hub, pm, %{to_role: "all", message: "Local"})

    assert recipient == worker.node_id
    assert {:ok, %{messages: []}} = receive_messages(hub, other_pm)
    assert {:ok, %{messages: []}} = receive_messages(hub, outsider)
    assert {:ok, %{messages: []}} = receive_messages(hub, pm)
  end

  test "explicit fan-out deduplicates recipients and preserves FIFO order", %{hub: hub, pm: pm} do
    worker = join(hub, pm)

    assert {:ok, %{delivered_to: [recipient]}} =
             send_message(hub, pm, %{to: [worker.node_id, worker.node_id], message: "First"})

    assert recipient == worker.node_id
    assert {:ok, _} = send_message(hub, pm, %{to: [worker.node_id], message: "Second"})
    assert {:ok, %{messages: messages}} = receive_messages(hub, worker)
    assert Enum.map(messages, & &1.message) == ["First", "Second"]
  end

  test "unknown recipients and inbox capacity reject the whole broadcast", %{hub: hub, pm: pm} do
    worker = join(hub, pm)
    other = join(hub, pm)

    assert {:error, _} =
             send_message(hub, pm, %{to: [worker.node_id, "missing"], message: "Task"})

    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
    for text <- ["One", "Two"], do: send_message(hub, pm, %{to: [worker.node_id], message: text})
    assert {:error, _} = send_message(hub, pm, %{to_role: "worker", message: "Three"})
    assert {:ok, %{messages: []}} = receive_messages(hub, other)
    assert {:ok, %{messages: [_, _]}} = receive_messages(hub, worker)
  end

  test "invalid targeting and messages do not deliver", %{hub: hub, pm: pm} do
    worker = join(hub, pm)

    for fields <- [
          %{to: [], message: "Task"},
          %{to: [worker.node_id], to_role: "worker", message: "Task"},
          %{message: "Task"},
          %{to: [worker.node_id], message: "  "},
          %{to: [worker.node_id]},
          %{to: [worker.node_id], message: String.duplicate("a", 65_537)}
        ] do
      assert {:error, _} = send_message(hub, pm, fields)
    end

    assert {:ok, %{messages: []}} = receive_messages(hub, worker)
  end

  test "public snapshots retain ring routes without exposing credentials or draining inboxes", %{
    hub: hub,
    pm: pm
  } do
    worker = join(hub, pm)

    assert {:ok, %{message_id: id}} =
             send_message(hub, pm, %{to: [worker.node_id], message: "Task"})

    assert {:ok, %{messages: [event]} = snapshot} = Hub.snapshot(hub)
    assert event.id == id
    assert event.ring_id == pm.ring_id
    assert event.to == [worker.node_id]
    assert event.received_by == []
    public_json = Jason.encode!(snapshot)

    credentials_leaked =
      Enum.any?([pm.token, worker.token, pm.ring_token], &String.contains?(public_json, &1))

    refute credentials_leaked, "operator snapshots must not expose invitation or node tokens"
    assert {:ok, %{messages: [%{id: ^id}]}} = receive_messages(hub, worker)
  end

  test "operator history retains the newest 50 sends after inboxes are drained", %{
    hub: hub,
    pm: pm
  } do
    worker = join(hub, pm)

    for number <- 1..55 do
      assert {:ok, _} =
               send_message(hub, pm, %{to: [worker.node_id], message: "Message #{number}"})

      assert {:ok, _} = receive_messages(hub, worker)
    end

    assert {:ok, %{messages: history, history_limit: 50}} = Hub.snapshot(hub)
    assert length(history) == 50
    assert hd(history).message == "Message 55"
    assert List.last(history).message == "Message 6"
    assert {:error, _} = send_message(hub, pm, %{to: ["missing"], message: "Failed"})
    assert {:ok, %{messages: ^history}} = Hub.snapshot(hub)
  end

  test "collection status tracks each recipient separately", %{hub: hub, pm: pm} do
    first = join(hub, pm)
    second = join(hub, pm)
    assert {:ok, _} = send_message(hub, pm, %{to_role: "worker", message: "Start"})
    receive_messages(hub, first)
    assert {:ok, %{messages: [%{received_by: [collected]}]}} = Hub.snapshot(hub)
    assert collected == first.node_id
    receive_messages(hub, second)
    assert {:ok, %{messages: [%{received_by: recipients}]}} = Hub.snapshot(hub)
    assert Enum.sort(recipients) == Enum.sort([first.node_id, second.node_id])
  end

  test "configured history limit trims the log without truncating the inbox" do
    hub =
      start_supervised!(
        Supervisor.child_spec({Hub, name: nil, history_limit: 2}, id: :limited_history)
      )

    pm = register(hub, %{role: "pm"})
    worker = join(hub, pm)

    for number <- 1..4,
        do: send_message(hub, pm, %{to: [worker.node_id], message: "Message #{number}"})

    assert {:ok, %{messages: history, history_limit: 2}} = Hub.snapshot(hub)
    assert Enum.map(history, & &1.message) == ["Message 4", "Message 3"]
    assert {:ok, %{messages: inbox}} = receive_messages(hub, worker)
    assert Enum.map(inbox, & &1.message) == Enum.map(1..4, &"Message #{&1}")
  end

  test "IDs are never reused after expiry or hub replacement within the server VM", %{
    hub: hub,
    clock: clock,
    pm: pm
  } do
    workers = for _ <- 1..20, do: join(hub, pm)
    Agent.update(clock, fn _ -> 1000 end)
    new_pm = register(hub, %{role: "pm", ring_token: pm.ring_token})
    more_workers = for _ <- 1..20, do: join(hub, new_pm)
    replacement = start_supervised!(Supervisor.child_spec({Hub, name: nil}, id: :replacement))

    assert {:error, "invalid ring token"} =
             Hub.register(%{role: "worker", ring_token: pm.ring_token}, replacement)

    replaced_pm = register(replacement, %{role: "pm"})
    ids = Enum.map([pm, new_pm, replaced_pm | workers ++ more_workers], & &1.node_id)
    assert length(Enum.uniq(ids)) == length(ids)
    assert new_pm.ring_id == pm.ring_id
  end

  test "concurrent role-only joins receive distinct IDs in the same ring", %{hub: hub, pm: pm} do
    results =
      1..40
      |> Enum.map(fn _ -> Task.async(fn -> join(hub, pm) end) end)
      |> Enum.map(&Task.await/1)

    assert length(Enum.uniq_by(results, & &1.node_id)) == 40
    assert Enum.all?(results, &(&1.ring_id == pm.ring_id))
  end

  test "presence sweeps publish expiry without a tool call", %{clock: clock} do
    start_supervised!({Phoenix.PubSub, name: AgentTalk.HubTestPubSub})
    Phoenix.PubSub.subscribe(AgentTalk.HubTestPubSub, Hub.topic())

    hub =
      start_supervised!(
        Supervisor.child_spec(
          {Hub,
           name: nil,
           ttl_ms: 1000,
           clock: fn -> Agent.get(clock, & &1) end,
           pubsub: AgentTalk.HubTestPubSub},
          id: :observed
        )
      )

    register(hub, %{role: "pm"})
    assert_receive :hub_updated
    Agent.update(clock, fn _ -> 1000 end)
    send(hub, :sweep)
    assert_receive :hub_updated
    assert {:ok, %{nodes: []}} = Hub.snapshot(hub)
  end

  defp register(hub, args) do
    {:ok, node} = Hub.register(args, hub)
    node
  end

  defp join(hub, pm, role \\ "worker"),
    do: register(hub, %{role: role, ring_token: pm.ring_token})

  defp auth(node, fields \\ %{}),
    do: Map.merge(%{node_id: node.node_id, token: node.token}, fields)

  defp send_message(hub, node, fields),
    do: Hub.communicate(auth(node, Map.put(fields, :action, "send")), hub)

  defp receive_messages(hub, node), do: Hub.communicate(auth(node, %{action: "receive"}), hub)
end
