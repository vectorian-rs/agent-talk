defmodule AgentTalk.Hub do
  @moduledoc "Serializes registration and fan-out into ephemeral, per-agent mailboxes."
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register(args, server \\ __MODULE__), do: GenServer.call(server, {:register, args})
  def list_nodes(role \\ nil, server \\ __MODULE__), do: GenServer.call(server, {:list, role})
  def communicate(args, server \\ __MODULE__), do: GenServer.call(server, {:communicate, args})
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  def topic, do: "agent-talk:operator"

  @impl true
  def init(opts) do
    Process.send_after(self(), :sweep, 1000)

    {:ok,
     %{
       nodes: %{},
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
    %{node_id: id, role: role} = args
    existing = state.nodes[id]

    cond do
      not valid_id?(id) ->
        {{:error, "node_id must be 1..64 letters, digits, underscores, dots or hyphens"}, state}

      role not in ["pm", "implementation"] ->
        {{:error, "role must be pm or implementation"}, state}

      existing != nil and Map.get(args, :token) != existing.token ->
        {{:error, "node_id is already registered; its token is required to renew it"}, state}

      true ->
        node =
          (existing || %{node_id: id, token: random_id(), inbox: :queue.new()})
          |> Map.merge(%{role: role, seen_at: now, last_seen: timestamp()})

        data =
          Map.merge(public_node(node), %{
            token: node.token,
            expires_in_seconds: state.ttl_ms / 1000
          })

        {{:ok, data}, put_in(state.nodes[id], node)}
    end
  end

  defp dispatch({:list, role}, state, _now) do
    nodes = Enum.filter(public_nodes(state.nodes), &(is_nil(role) or &1.role == role))
    {{:ok, %{nodes: nodes}}, state}
  end

  defp dispatch({:communicate, args}, state, now) do
    case state.nodes[args.node_id] do
      nil ->
        {{:error, "node is not registered or has expired; call register_node"}, state}

      %{token: token} = node when token == args.token ->
        state = put_in(state.nodes[node.node_id], %{node | seen_at: now, last_seen: timestamp()})
        communicate(args, state, node)

      _node ->
        {{:error, "invalid node token"}, state}
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
         {:ok, recipients} <- recipients(args, state.nodes, node.node_id),
         :ok <- check_capacity(recipients, state) do
      message = %{
        id: random_id(),
        from: node.node_id,
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

      to == nil and role in ["pm", "implementation", "all"] ->
        ids =
          nodes
          |> Map.values()
          |> Enum.filter(&(&1.node_id != sender and (role == "all" or &1.role == role)))
          |> Enum.map(& &1.node_id)
          |> Enum.sort()

        if ids == [], do: {:error, "no matching recipients"}, else: {:ok, ids}

      true ->
        {:error, "send requires a nonempty to list or to_role (pm, implementation or all)"}
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
  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp public_nodes(nodes) do
    nodes |> Map.values() |> Enum.sort_by(& &1.node_id) |> Enum.map(&public_node/1)
  end

  defp history_limit(state),
    do:
      Map.get(state, :history_limit, Application.get_env(:agent_talk, :message_history_limit, 50))

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
      last_seen: node.last_seen,
      pending_messages: :queue.len(node.inbox)
    }
  end
end
