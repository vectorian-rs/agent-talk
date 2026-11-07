defmodule AgentTalk.Hub do
  @moduledoc "Serializes ring membership and fan-out into ephemeral, per-agent mailboxes."
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register(args, server \\ __MODULE__), do: GenServer.call(server, {:register, args})
  def list_nodes(args, server \\ __MODULE__), do: GenServer.call(server, {:list, args})
  def communicate(args, server \\ __MODULE__), do: GenServer.call(server, {:communicate, args})
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  def topic, do: "agent-talk:operator"

  @impl true
  def init(opts) do
    Process.send_after(self(), :sweep, 1000)

    {:ok,
     %{
       nodes: %{},
       rings: %{},
       messages: [],
       pubsub: Keyword.get(opts, :pubsub),
       ttl_ms:
         Keyword.get_lazy(opts, :ttl_ms, fn ->
           Application.fetch_env!(:agent_talk, :node_ttl_ms)
         end),
       history_limit:
         Keyword.get_lazy(opts, :history_limit, fn ->
           Application.fetch_env!(:agent_talk, :message_history_limit)
         end),
       max_inbox: Keyword.get(opts, :max_inbox, 1000),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call(request, _from, state) do
    now = state.clock.()
    {reply, updated} = dispatch(request, expire_nodes(state, now), now)
    notify_if_changed(state, updated)
    {:reply, reply, updated}
  end

  @impl true
  def handle_info(:sweep, state) do
    updated = expire_nodes(state, state.clock.())
    notify_if_changed(state, updated)
    Process.send_after(self(), :sweep, 1000)
    {:noreply, updated}
  end

  defp dispatch(:snapshot, state, _now) do
    data = %{
      nodes: public_nodes(state.nodes),
      messages: state.messages,
      history_limit: history_limit(state)
    }

    {{:ok, data}, state}
  end

  defp dispatch({:register, args}, state, now) do
    role = Map.get(args, :role)
    id = Map.get(args, :node_id)
    token = Map.get(args, :token)

    cond do
      not valid_id?(role) ->
        {{:error, "role must be 1..64 letters, digits, underscores, dots or hyphens"}, state}

      role == "all" ->
        {{:error, "role all is reserved for broadcasts"}, state}

      id == nil and token == nil ->
        join_ring(args, state, now)

      id == nil or token == nil ->
        {{:error, "renewal requires both node_id and token; a new join uses role and ring_token"},
         state}

      true ->
        case state.nodes[id] do
          nil ->
            {{:error,
              "node is not registered or has expired; join again with role and ring_token"},
             state}

          node ->
            cond do
              token != node.token ->
                {{:error, "invalid node token"}, state}

              role != node.role ->
                {{:error, "renewal cannot change role"}, state}

              Map.get(args, :ring_token) != nil and
                  args.ring_token != state.rings[node.ring_id] ->
                {{:error, "ring_token does not match this node's ring"}, state}

              true ->
                node = %{node | seen_at: now, last_seen: timestamp()}
                updated = put_in(state.nodes[id], node)
                {{:ok, registration(node, updated)}, updated}
            end
        end
    end
  end

  defp dispatch({:list, args}, state, now) do
    with {:ok, caller, updated} <- authenticate(args, state, now) do
      role = Map.get(args, :role)

      if role == nil or valid_id?(role) do
        nodes =
          public_nodes(updated.nodes)
          |> Enum.filter(&(&1.ring_id == caller.ring_id and (role == nil or &1.role == role)))

        {{:ok, %{ring_id: caller.ring_id, nodes: nodes}}, updated}
      else
        {{:error, "invalid role filter"}, updated}
      end
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp dispatch({:communicate, args}, state, now) do
    case authenticate(args, state, now) do
      {:ok, node, updated} -> communicate(args, updated, node)
      {:error, _} = error -> {error, state}
    end
  end

  defp join_ring(args, state, now) do
    case {args.role, Map.get(args, :ring_token)} do
      {"pm", nil} ->
        ring_id = unique_id("ring")
        state = put_in(state.rings[ring_id], new_token())
        add_node(args.role, ring_id, state, now)

      {_role, nil} ->
        {{:error, "ring_token is required; ask the PM for an onboarding prompt"}, state}

      {role, ring_token} ->
        case Enum.find(state.rings, fn {_id, token} -> token == ring_token end) do
          {ring_id, _token} -> add_node(role, ring_id, state, now)
          nil -> {{:error, "invalid ring token"}, state}
        end
    end
  end

  defp add_node(role, ring_id, state, now) do
    node = %{
      node_id: unique_id("node"),
      role: role,
      ring_id: ring_id,
      token: new_token(),
      inbox: :queue.new(),
      seen_at: now,
      last_seen: timestamp()
    }

    updated = put_in(state.nodes[node.node_id], node)
    {{:ok, registration(node, updated)}, updated}
  end

  defp registration(node, state) do
    data =
      Map.merge(public_node(node), %{
        token: node.token,
        ring_token: state.rings[node.ring_id],
        expires_in_seconds: state.ttl_ms / 1000,
        instructions: """
        Save this complete response privately before another call; never publish either token.
        Renew with role, node_id and token. Use list_nodes with node_id and token to discover
        members of this ring; optionally filter by role. Use communicate to send to those IDs
        or to_role, or receive your inbox between tasks. Wait for the operator to resume idle
        agents; do not start endless polling or other agents. After expiry, join again with
        role and ring_token, save the new identity, and reconcile work with the project record.
        Ring tokens invite members; only your private node token authenticates your calls.
        """
      })

    if node.role == "pm" do
      Map.put(data, :onboarding_prompt_template, """
      Follow this project's instructions for <ROLE>. Join AgentTalk ring #{node.ring_id}.
      Resume this session's saved credentials only if role and ring match; otherwise call
      register_node with role=<ROLE> and ring_token=<RING_TOKEN>. Save the complete response
      privately and follow its instructions. Report ready to PM #{node.node_id} in this ring.
      """)
    else
      data
    end
  end

  defp authenticate(args, state, now) do
    case state.nodes[Map.get(args, :node_id)] do
      nil ->
        {:error, "node is not registered or has expired; join again with role and ring_token"}

      node ->
        if Map.get(args, :token) == node.token do
          updated =
            put_in(state.nodes[node.node_id], %{node | seen_at: now, last_seen: timestamp()})

          {:ok, node, updated}
        else
          {:error, "invalid node token"}
        end
    end
  end

  defp communicate(%{action: "receive"} = args, state, node) do
    if Map.get(args, :to) != nil or Map.get(args, :to_role) != nil or
         Map.get(args, :message) != nil do
      {{:error, "receive takes no to, to_role or message fields"}, state}
    else
      messages = :queue.to_list(node.inbox)
      received_ids = MapSet.new(messages, & &1.id)

      history =
        Enum.map(state.messages, fn event ->
          if MapSet.member?(received_ids, event.id) do
            %{event | received_by: Enum.uniq([node.node_id | event.received_by])}
          else
            event
          end
        end)

      updated = put_in(state.nodes[node.node_id].inbox, :queue.new())
      {{:ok, %{messages: messages}}, %{updated | messages: history}}
    end
  end

  defp communicate(%{action: "send"} = args, state, node) do
    with :ok <- validate_message(Map.get(args, :message)),
         {:ok, recipients} <- recipients(args, ring_nodes(state, node.ring_id), node.node_id),
         :ok <- check_capacity(recipients, state) do
      message = %{
        id: unique_id("message"),
        from: node.node_id,
        ring_id: node.ring_id,
        message: args.message,
        sent_at: timestamp()
      }

      nodes =
        Enum.reduce(recipients, state.nodes, fn id, nodes ->
          update_in(nodes[id].inbox, &:queue.in(message, &1))
        end)

      event = Map.merge(message, %{to: recipients, from_role: node.role, received_by: []})
      history = Enum.take([event | state.messages], history_limit(state))

      {{:ok, %{message_id: message.id, delivered_to: recipients}},
       %{state | nodes: nodes, messages: history}}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp recipients(args, nodes, sender) do
    to = Map.get(args, :to)
    role = Map.get(args, :to_role)

    cond do
      to != nil and role != nil ->
        {:error, "provide either to or to_role, not both"}

      is_list(to) and to != [] and Enum.all?(to, &valid_id?/1) ->
        ids = Enum.uniq(to)
        missing = Enum.reject(ids, &Map.has_key?(nodes, &1))

        if missing == [],
          do: {:ok, ids},
          else: {:error, "unknown or expired recipients: #{Enum.join(missing, ", ")}"}

      to == nil and valid_id?(role) ->
        ids =
          nodes
          |> Map.values()
          |> Enum.filter(&(&1.node_id != sender and (role == "all" or &1.role == role)))
          |> Enum.map(& &1.node_id)
          |> Enum.sort()

        if ids == [], do: {:error, "no matching recipients"}, else: {:ok, ids}

      true ->
        {:error, "send requires a nonempty to list or to_role (a role or all)"}
    end
  end

  defp check_capacity(recipients, state) do
    if Enum.any?(recipients, &(:queue.len(state.nodes[&1].inbox) >= state.max_inbox)) do
      {:error, "a recipient inbox is full; no messages were delivered"}
    else
      :ok
    end
  end

  defp validate_message(message) when is_binary(message) do
    if String.trim(message) != "" and byte_size(message) <= 65_536,
      do: :ok,
      else: {:error, "message must be nonempty and at most 65536 bytes"}
  end

  defp validate_message(_), do: {:error, "message is required when sending"}

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,64}\z/, id)
  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp new_token do
    :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)) |> Base.url_encode64(padding: false)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp ring_nodes(state, ring_id),
    do: Map.filter(state.nodes, fn {_id, node} -> node.ring_id == ring_id end)

  defp public_nodes(nodes) do
    nodes |> Map.values() |> Enum.sort_by(& &1.node_id) |> Enum.map(&public_node/1)
  end

  defp history_limit(state), do: state.history_limit

  defp expire_nodes(state, now) do
    nodes = Map.reject(state.nodes, fn {_id, node} -> now - node.seen_at >= state.ttl_ms end)
    %{state | nodes: nodes}
  end

  defp notify_if_changed(previous, updated) do
    if updated.pubsub &&
         (previous.nodes != updated.nodes or previous.messages != updated.messages) do
      Phoenix.PubSub.broadcast(updated.pubsub, topic(), :hub_updated)
    end
  end

  defp public_node(node) do
    %{
      node_id: node.node_id,
      role: node.role,
      ring_id: node.ring_id,
      last_seen: node.last_seen,
      pending_messages: :queue.len(node.inbox)
    }
  end
end
