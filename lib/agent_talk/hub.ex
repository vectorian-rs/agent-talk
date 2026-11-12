defmodule AgentTalk.Hub do
  @moduledoc "Serializes ring membership and fan-out into ephemeral, per-agent mailboxes."
  use GenServer
  alias AgentTalk.{History, MembershipStore}

  # Errors are {:error, code, message}: the code is the machine-readable
  # contract (sent to clients in structuredContent.error.code by
  # AgentTalk.tool_reply); the message is advisory prose, free to change.
  # Codes: :invalid_request, :invalid_labels, :invalid_ring_token,
  # :invalid_token, :expired, :inbox_full, :storage.
  @labels_error "project, name and purpose must be nonempty labels of at most 128 characters without control characters"

  # Free-text display and discovery labels a caller sets on its own node, set at
  # register and updatable on list_nodes. purpose is the one line a searcher
  # reads to route by capability ("whoever does the deployments").
  @label_fields [:project, :name, :purpose]
  @missing_node_error "node is not registered or has expired; join again with role and ring_token"
  @invalid_token_error "invalid node token"

  # The inbox copy of a message. Recovery rebuilds exactly this shape from
  # archived events, so live sends and restored copies must share this one
  # definition; UI/archive-only metadata stays out of inbox payloads.
  @message_fields [:id, :from, :ring_id, :message, :sent_at, :reply_to]

  # Synthetic sender for operator broadcasts. "operator" is not a registered
  # node and owns no token, so it can address a ring but never authenticate.
  @operator_id "operator"
  @operator_role "operator"
  @operator_name "Operator"

  # Longest wait a list_nodes call may be parked, under common 30-second
  # HTTP/proxy request timeouts (Anubis's plug allows 30s per request).
  @wait_cap_ms 25_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register(args, server \\ __MODULE__), do: GenServer.call(server, {:register, args})

  def list_nodes(args, server \\ __MODULE__),
    do: GenServer.call(server, {:list, args}, call_timeout(args))

  # A waited call must outlive its park; the server clamp decides the real
  # grant, this only keeps the caller's timeout above any possible grant.
  defp call_timeout(args) do
    case Map.get(args, :wait_seconds) do
      seconds when is_integer(seconds) and seconds >= 0 -> wait_cap_ms(seconds) + 5_000
      _ -> 5_000
    end
  end

  # The hold a request may be granted, before the per-call ttl/2 term; shared so
  # the client timeout and the server grant can never disagree on the cap.
  defp wait_cap_ms(seconds), do: min(seconds * 1000, @wait_cap_ms)

  def communicate(args, server \\ __MODULE__), do: GenServer.call(server, {:communicate, args})
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  # Operator-initiated removal of a node (force-expire). Called in-process from
  # the trusted local dashboard, not over MCP, so it takes no token.
  def evict(node_id, server \\ __MODULE__), do: GenServer.call(server, {:evict, node_id})

  # Operator-initiated broadcast to every member of a ring. Trusted local
  # dashboard call (no token); delivers from a synthetic "operator" sender.
  def broadcast(ring_id, message, server \\ __MODULE__),
    do: GenServer.call(server, {:broadcast, ring_id, message})

  def topic, do: "agent-talk:operator"

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state =
      %{
        nodes: %{},
        rings: %{},
        next_id: 0,
        messages: [],
        waiters: %{},
        membership_file: Keyword.get(opts, :membership_file),
        history_file: Keyword.get(opts, :history_file),
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
        clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
        wall_clock: Keyword.get(opts, :wall_clock, fn -> System.system_time(:millisecond) end)
      }

    Process.send_after(self(), :sweep, sweep_interval(state))
    now = state.clock.()

    with {:ok, saved} <- MembershipStore.load(state.membership_file),
         {:ok, db} <- History.open(state.history_file) do
      # Expired memberships are gone after restore/3, so pending rows for the
      # surviving IDs are exactly the queued mail lost at shutdown. A failed
      # query stops startup; it must not fake empty inboxes.
      result =
        with {:ok, messages} <- History.recent(db, state.history_limit),
             {:ok, counter} <- History.last_counter(db),
             restored =
               state
               |> restore(saved, now)
               |> Map.merge(%{
                 next_id: max(saved.next_id, counter),
                 messages: messages,
                 history_db: db
               }),
             {:ok, pending} <- History.pending(db, Map.keys(restored.nodes)),
             restored = recover_inboxes(restored, pending),
             :ok <- MembershipStore.save(state.membership_file, restored) do
          {:ok, restored}
        end

      case result do
        {:ok, restored} ->
          {:ok, restored}

        _ ->
          History.close(db)
          {:stop, :storage_unavailable}
      end
    else
      {:error, _} -> {:stop, :storage_unavailable}
    end
  end

  defp restore(state, saved, now) do
    wall_now = state.wall_clock.()

    nodes =
      Map.new(saved.nodes, fn {id, node} ->
        {:ok, last_seen, _offset} = DateTime.from_iso8601(node.last_seen)
        elapsed = max(0, wall_now - DateTime.to_unix(last_seen, :millisecond))
        {id, Map.merge(node, %{inbox: :queue.new(), seen_at: now - elapsed})}
      end)

    state
    |> Map.merge(%{saved | nodes: nodes})
    |> Map.merge(%{presence_dirty: false, presence_flushed_at: now})
    |> expire_nodes(now)
  end

  defp inbox_message(event), do: Map.take(event, @message_fields)

  defp deliver(nodes, recipients, copy) do
    Enum.reduce(recipients, nodes, fn id, nodes ->
      update_in(nodes[id].inbox, &:queue.in(copy, &1))
    end)
  end

  # Restores every pending delivery, deliberately ignoring max_inbox: the
  # backlog was accepted before shutdown, and check_capacity/2 already
  # rejects new mail until it drains. The operator window (state.messages)
  # is left untouched — recovery is not history.
  defp recover_inboxes(state, pending) do
    nodes =
      Enum.reduce(pending, state.nodes, fn event, nodes ->
        recipients =
          Enum.filter(event.to, &(Map.has_key?(nodes, &1) and &1 not in event.received_by))

        deliver(nodes, recipients, inbox_message(event))
      end)

    %{state | nodes: nodes}
  end

  @impl true
  def handle_call(request, from, state) do
    now = state.clock.()
    {reply, updated} = dispatch(request, expire_nodes(state, now), now)

    case persist(state, updated, now) do
      {:ok, persisted} ->
        case History.record(
               Map.get(state, :history_db),
               request,
               reply,
               persisted,
               timestamp(persisted)
             ) do
          :ok ->
            notify_if_changed(state, persisted)
            respond(reply, from, wake_ready_waiters(persisted))

          {:error, _} ->
            retained = restore_mailboxes(state, persisted)
            notify_if_changed(state, retained)

            {:reply,
             {:error, :storage,
              "conversation archive unavailable; message operation was not applied"}, retained}
        end

      {:error, _} ->
        {:reply,
         {:error, :storage, "membership storage unavailable; check the server's membership_file"},
         state}
    end
  end

  @impl true
  def terminate(_reason, state), do: History.close(Map.get(state, :history_db))

  @impl true
  def handle_info(:sweep, state) do
    now = state.clock.()
    updated = expire_nodes(state, now)
    Process.send_after(self(), :sweep, sweep_interval(state))

    case persist(state, updated, now) do
      {:ok, persisted} ->
        notify_if_changed(state, persisted)
        {:noreply, wake_ready_waiters(persisted)}

      {:error, _} ->
        {:noreply, state}
    end
  end

  # Cancelling a timer cannot unsend an already-queued timeout, so a timeout
  # acts only when it carries the current park's exact timer reference.
  @impl true
  def handle_info({:timeout, timer, {:waiter_timeout, node_id}}, state) do
    case Map.get(state.waiters, node_id) do
      {_from, ^timer, _args} ->
        # Expire first, as handle_call and :sweep do: a lease that lapsed while
        # parked must not be revived by the timeout's renewing re-dispatch.
        {:noreply, wake_waiter(expire_nodes(state, state.clock.()), node_id)}

      _ ->
        {:noreply, state}
    end
  end

  defp respond({:park, node_id, wait_ms, args}, from, state),
    do: {:noreply, park_waiter(state, node_id, from, wait_ms, args)}

  defp respond(reply, _from, state), do: {:reply, reply, state}

  # At most one park per node: a replacement releases the previous caller
  # with a normal woken reply before storing the new one.
  defp park_waiter(state, node_id, from, wait_ms, args) do
    state = wake_waiter(state, node_id)
    timer = :erlang.start_timer(wait_ms, self(), {:waiter_timeout, node_id})
    put_in(state.waiters[node_id], {from, timer, args})
  end

  # Waking is re-dispatch, not a second reply path: the stored args minus the
  # wait run back through the normal list pipeline (a node gone since parking
  # yields the usual expired error), and only waited_seconds — the original
  # grant, recomputed — is layered on top. The re-dispatch renews the lease,
  # a presence-only change, so it is deferred to the regular presence flush.
  # Label fields are dropped: they were applied when the request first arrived,
  # so replaying them would revert a renewal that landed while the caller parked.
  defp wake_waiter(state, node_id) do
    case Map.pop(state.waiters, node_id) do
      {nil, _waiters} ->
        state

      {{from, timer, args}, waiters} ->
        :erlang.cancel_timer(timer)
        state = %{state | waiters: waiters}
        {:ok, wait_ms} = effective_wait(args, state)

        {reply, updated} =
          dispatch(
            {:list, Map.drop(args, [:wait_seconds | @label_fields])},
            state,
            state.clock.()
          )

        GenServer.reply(
          from,
          with {:ok, payload} <- reply do
            {:ok, Map.put(payload, :waited_seconds, wait_ms / 1000)}
          end
        )

        # Only a successful wake renewed the lease; a gone node returns an error
        # with unchanged state, so it must not trigger a spurious presence flush.
        case reply do
          {:ok, _} -> %{updated | presence_dirty: true}
          _ -> updated
        end
    end
  end

  # Runs after every serialized state change. The wake predicate is hardwired
  # to "own inbox non-empty or node gone"; a future caller watching anything
  # else gets an explicit wait_for argument here, not a second parking
  # mechanism.
  defp wake_ready_waiters(state) do
    Enum.reduce(Map.keys(state.waiters), state, fn node_id, state ->
      case state.nodes[node_id] do
        %{inbox: inbox} -> if :queue.is_empty(inbox), do: state, else: wake_waiter(state, node_id)
        nil -> wake_waiter(state, node_id)
      end
    end)
  end

  # Expiry is also enforced on every call; the timer only covers idle servers.
  defp sweep_interval(state), do: state.ttl_ms |> div(20) |> min(60_000) |> max(1000)

  defp dispatch(:snapshot, state, _now) do
    pending =
      Map.new(state.nodes, fn {id, node} ->
        {id, MapSet.new(:queue.to_list(node.inbox), & &1.id)}
      end)

    empty = MapSet.new()

    messages =
      Enum.map(state.messages, fn event ->
        Map.put(
          event,
          :pending_to,
          Enum.filter(event.to, &MapSet.member?(Map.get(pending, &1, empty), event.id))
        )
      end)

    data = %{
      nodes: public_nodes(state.nodes),
      messages: messages,
      history_limit: state.history_limit,
      history_persistent: not is_nil(Map.get(state, :history_db))
    }

    {{:ok, data}, state}
  end

  # Drop a node exactly as a lease expiry would: its queued mail goes with it,
  # and handle_call's persist + broadcast then apply. Idempotent — an unknown or
  # already-gone id reports evicted: false and changes nothing.
  defp dispatch({:evict, node_id}, state, _now) do
    {existing, nodes} = Map.pop(state.nodes, node_id)
    {{:ok, %{evicted: existing != nil}}, %{state | nodes: nodes}}
  end

  # Fan one operator message out to every current member of a ring, built and
  # delivered through emit_event/5 from a synthetic operator sender (no ring
  # project, so project is nil). handle_call's persist + archive + broadcast +
  # wake-waiters wrapper then applies, exactly as for a send.
  defp dispatch({:broadcast, ring_id, message}, state, _now) do
    recipients = state |> ring_nodes(ring_id) |> Map.keys() |> Enum.sort()

    with :ok <- validate_message(message),
         :ok <- validate_recipients(recipients),
         :ok <- check_capacity(recipients, state) do
      sender = %{
        id: @operator_id,
        role: @operator_role,
        name: @operator_name,
        project: nil,
        ring_id: ring_id
      }

      emit_event(state, sender, recipients, message, nil)
    else
      {:error, _, _} = error -> {error, state}
    end
  end

  defp dispatch({:register, args}, state, now) do
    role = Map.get(args, :role)
    id = Map.get(args, :node_id)
    token = Map.get(args, :token)

    cond do
      not valid_id?(role) ->
        {{:error, :invalid_request,
          "role must be 1..64 letters, digits, underscores, dots or hyphens"}, state}

      role == "all" ->
        {{:error, :invalid_request, "role all is reserved for broadcasts"}, state}

      not valid_labels?(args) ->
        {{:error, :invalid_labels, @labels_error}, state}

      id == nil and token == nil ->
        join_ring(args, state, now)

      id == nil or token == nil ->
        {{:error, :invalid_request,
          "renewal requires both node_id and token; a new join uses role and ring_token"}, state}

      true ->
        renew_node(args, state, now)
    end
  end

  defp dispatch({:list, args}, state, now) do
    with {:ok, caller, updated} <- authenticate(args, state, now) do
      role = Map.get(args, :role)

      cond do
        not valid_labels?(args) ->
          {{:error, :invalid_labels, @labels_error}, updated}

        role != nil and not valid_id?(role) ->
          {{:error, :invalid_request, "invalid role filter"}, updated}

        true ->
          case effective_wait(args, updated) do
            {:error, _, _} = error ->
              {error, updated}

            {:ok, wait_ms} ->
              updated =
                update_in(
                  updated.nodes[caller.node_id],
                  &Map.merge(&1, Map.take(args, @label_fields))
                )

              nodes =
                ring_nodes(updated, caller.ring_id)
                |> public_nodes()
                |> Enum.filter(&(role == nil or &1.role == role))

              next_message_id =
                case :queue.peek(caller.inbox) do
                  {:value, message} -> message.id
                  :empty -> nil
                end

              inbox = %{
                pending_messages: :queue.len(caller.inbox),
                next_message_id: next_message_id
              }

              payload = %{ring_id: caller.ring_id, nodes: nodes, inbox: inbox}

              cond do
                wait_ms == nil ->
                  {{:ok, payload}, updated}

                inbox.pending_messages == 0 and wait_ms > 0 ->
                  {{:park, caller.node_id, wait_ms, args}, updated}

                true ->
                  {{:ok, Map.put(payload, :waited_seconds, 0)}, updated}
              end
          end
      end
    else
      {:error, _, _} = error -> {error, state}
    end
  end

  defp dispatch({:communicate, args}, state, now) do
    case authenticate(args, state, now) do
      {:ok, node, updated} -> communicate(args, updated, node)
      {:error, _, _} = error -> {error, state}
    end
  end

  # Only waited requests gain waited_seconds; plain replies stay byte-identical
  # to a server without this feature. The clamp is the single authority on the
  # grant: under common 30s proxy timeouts and at most half the lease, so a
  # parked healthy node never expires mid-wait.
  defp effective_wait(args, state) do
    case Map.get(args, :wait_seconds) do
      nil ->
        {:ok, nil}

      seconds when is_integer(seconds) and seconds >= 0 ->
        {:ok, min(wait_cap_ms(seconds), div(state.ttl_ms, 2))}

      _ ->
        {:error, :invalid_request, "wait_seconds must be a non-negative integer"}
    end
  end

  defp renew_node(args, state, now) do
    case state.nodes[args.node_id] do
      nil ->
        {{:error, :expired, @missing_node_error}, state}

      node ->
        cond do
          args.token != node.token ->
            {{:error, :invalid_token, @invalid_token_error}, state}

          args.role != node.role ->
            {{:error, :invalid_request, "renewal cannot change role"}, state}

          Map.get(args, :ring_token) != nil and
              args.ring_token != state.rings[node.ring_id] ->
            {{:error, :invalid_ring_token, "ring_token does not match this node's ring"}, state}

          true ->
            node =
              node
              |> Map.merge(Map.take(args, @label_fields))
              |> Map.merge(%{seen_at: now, last_seen: timestamp(state)})

            updated = put_in(state.nodes[node.node_id], node)
            {{:ok, registration(node, updated)}, updated}
        end
    end
  end

  defp join_ring(args, state, now) do
    case {args.role, Map.get(args, :ring_token)} do
      {"pm", nil} ->
        {ring_id, state} = allocate_id("ring", state)
        state = put_in(state.rings[ring_id], new_token())
        add_node(args, ring_id, state, now)

      {_role, nil} ->
        {{:error, :invalid_request,
          "ring_token is required; ask the PM for an onboarding prompt"}, state}

      {_role, ring_token} ->
        case Enum.find(state.rings, fn {_id, token} -> token == ring_token end) do
          {ring_id, _token} -> add_node(args, ring_id, state, now)
          nil -> {{:error, :invalid_ring_token, "invalid ring token"}, state}
        end
    end
  end

  defp add_node(args, ring_id, state, now) do
    {node_id, state} = allocate_id("node", state)

    node = %{
      node_id: node_id,
      role: args.role,
      project: Map.get(args, :project),
      name: Map.get(args, :name),
      purpose: Map.get(args, :purpose),
      ring_id: ring_id,
      token: new_token(),
      inbox: :queue.new(),
      seen_at: now,
      last_seen: timestamp(state)
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
        or to_role, or receive your inbox when notified or between tasks. An optional host
        integration can check list_nodes.inbox and wake your session without draining mail.
        Without an integration, the operator resumes idle agents. Do not use LLM turns for
        empty polling or start other agents. After expiry, join again with
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
        {:error, :expired, @missing_node_error}

      node ->
        if Map.get(args, :token) == node.token do
          updated =
            put_in(state.nodes[node.node_id], %{node | seen_at: now, last_seen: timestamp(state)})

          {:ok, node, updated}
        else
          {:error, :invalid_token, @invalid_token_error}
        end
    end
  end

  # Only send carries addressing and content; receive and status reject those
  # fields so a misdirected one is an error, not a silently ignored no-op.
  defp content_fields?(args) do
    Enum.any?([:to, :to_role, :message, :reply_to], &(Map.get(args, &1) != nil))
  end

  defp communicate(%{action: "receive"} = args, state, node) do
    cond do
      content_fields?(args) ->
        {{:error, :invalid_request, "receive takes no to, to_role, message or reply_to fields"},
         state}

      :queue.is_empty(node.inbox) ->
        {{:ok, %{messages: []}}, state}

      true ->
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
         :ok <- validate_reply_to(Map.get(args, :reply_to)),
         {:ok, recipients} <- recipients(args, ring_nodes(state, node.ring_id), node.node_id),
         :ok <- check_capacity(recipients, state) do
      sender = %{
        id: node.node_id,
        role: node.role,
        name: node_name(node),
        project: Map.get(node, :project),
        ring_id: node.ring_id
      }

      emit_event(state, sender, recipients, args.message, Map.get(args, :reply_to))
    else
      {:error, _, _} = error -> {error, state}
    end
  end

  # Read-only delivery visibility for the sender: its own recent sends still in
  # the history window, each with who has received it and who is still pending.
  # Derives entirely from state.messages; mutates nothing (the lease was already
  # renewed by authenticate/3).
  defp communicate(%{action: "status"} = args, state, node) do
    if content_fields?(args) do
      {{:error, :invalid_request, "status takes no to, to_role, message or reply_to fields"},
       state}
    else
      sent =
        for event <- state.messages, event.from == node.node_id do
          %{
            id: event.id,
            to: event.to,
            received_by: event.received_by,
            pending: event.to -- event.received_by,
            sent_at: event.sent_at,
            reply_to: event.reply_to
          }
        end

      {{:ok, %{sent: sent}}, state}
    end
  end

  defp recipients(args, nodes, sender) do
    to = Map.get(args, :to)
    role = Map.get(args, :to_role)

    cond do
      to != nil and role != nil ->
        {:error, :invalid_request, "provide either to or to_role, not both"}

      is_list(to) and to != [] and Enum.all?(to, &valid_id?/1) ->
        ids = Enum.uniq(to)
        missing = Enum.reject(ids, &Map.has_key?(nodes, &1))

        if missing == [],
          do: {:ok, ids},
          else:
            {:error, :invalid_request,
             "unknown or expired recipients: #{Enum.join(missing, ", ")}"}

      to == nil and valid_id?(role) ->
        ids =
          nodes
          |> Map.values()
          |> Enum.filter(&(&1.node_id != sender and (role == "all" or &1.role == role)))
          |> Enum.map(& &1.node_id)
          |> Enum.sort()

        if ids == [],
          do: {:error, :invalid_request, "no matching recipients"},
          else: {:ok, ids}

      true ->
        {:error, :invalid_request, "send requires a nonempty to list or to_role (a role or all)"}
    end
  end

  defp check_capacity(recipients, state) do
    if Enum.any?(recipients, &(:queue.len(state.nodes[&1].inbox) >= state.max_inbox)) do
      {:error, :inbox_full, "a recipient inbox is full; no messages were delivered"}
    else
      :ok
    end
  end

  defp validate_recipients([]),
    do: {:error, :invalid_request, "no agents are registered in this ring"}

  defp validate_recipients(_), do: :ok

  # Single construction + delivery site for a ring message. An agent send and an
  # operator broadcast each build a `sender` descriptor and call this, so the
  # event schema (see @message_fields) stays defined in exactly one place and
  # both paths archive, deliver and render identically.
  defp emit_event(state, sender, recipients, message, reply_to) do
    {id, state} = allocate_id("message", state)

    event = %{
      id: id,
      from: sender.id,
      ring_id: sender.ring_id,
      message: message,
      sent_at: timestamp(state),
      reply_to: reply_to,
      to: recipients,
      from_role: sender.role,
      from_name: sender.name,
      to_names: Map.new(recipients, &{&1, node_name(state.nodes[&1])}),
      project: sender.project,
      received_by: []
    }

    nodes = deliver(state.nodes, recipients, inbox_message(event))
    history = Enum.take([event | state.messages], state.history_limit)

    {{:ok, %{message_id: event.id, delivered_to: recipients}},
     %{state | nodes: nodes, messages: history}}
  end

  defp validate_message(message) when is_binary(message) do
    if String.trim(message) != "" and byte_size(message) <= 65_536,
      do: :ok,
      else: {:error, :invalid_request, "message must be nonempty and at most 65536 bytes"}
  end

  defp validate_message(_), do: {:error, :invalid_request, "message is required when sending"}

  # Shape-only on purpose: the in-memory window is bounded, so checking that
  # the parent exists would make validity depend on eviction timing, and a
  # reply to a pruned message is still a true statement about causality.
  defp validate_reply_to(nil), do: :ok

  defp validate_reply_to(id) do
    if valid_id?(id),
      do: :ok,
      else: {:error, :invalid_request, "reply_to must be a message id"}
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,64}\z/, id)

  defp valid_labels?(args) do
    Enum.all?(@label_fields, fn key ->
      case Map.get(args, key) do
        nil ->
          true

        value when is_binary(value) ->
          String.trim(value) != "" and String.length(value) <= 128 and
            not Regex.match?(~r/[[:cntrl:]]/, value)

        _ ->
          false
      end
    end)
  end

  defp node_name(node), do: Map.get(node, :name) || node.node_id

  defp allocate_id(prefix, state) do
    counter = max(state.next_id + 1, System.unique_integer([:positive, :monotonic]))
    {"#{prefix}-#{counter}", %{state | next_id: counter}}
  end

  defp new_token do
    :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)) |> Base.url_encode64(padding: false)
  end

  defp timestamp(state) do
    state.wall_clock.() |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end

  @persisted_fields AgentTalk.MembershipStore.node_fields() -- [:last_seen]

  # Writing the membership file on every heartbeat would fsync once per
  # authenticated call, so presence-only changes (last_seen bumps) are flushed
  # at most once per ttl/20; a restart loses at most that much lease activity.
  defp persist(previous, updated, now) do
    cond do
      previous.rings != updated.rings or previous.next_id != updated.next_id ->
        save_now(updated, now)

      previous.nodes == updated.nodes ->
        flush_presence(updated, now)

      nodes_shape(previous.nodes) == nodes_shape(updated.nodes) ->
        flush_presence(%{updated | presence_dirty: true}, now)

      true ->
        save_now(updated, now)
    end
  end

  defp flush_presence(%{presence_dirty: true} = state, now) do
    if now - state.presence_flushed_at >= div(state.ttl_ms, 20) do
      case save_now(state, now) do
        {:ok, flushed} ->
          {:ok, flushed}

        # Presence loss within a flush window is tolerated by design, so a
        # failed flush must not fail the caller's unrelated request; retry on
        # the next window. Structural saves still surface their own errors.
        {:error, _} ->
          {:ok, %{state | presence_flushed_at: now}}
      end
    else
      {:ok, state}
    end
  end

  defp flush_presence(state, _now), do: {:ok, state}

  defp save_now(state, now) do
    case MembershipStore.save(state.membership_file, state) do
      :ok -> {:ok, %{state | presence_dirty: false, presence_flushed_at: now}}
      {:error, _} = error -> error
    end
  end

  defp nodes_shape(nodes) do
    Map.new(nodes, fn {id, node} -> {id, Map.take(node, @persisted_fields)} end)
  end

  defp restore_mailboxes(previous, updated) do
    nodes =
      Map.new(updated.nodes, fn {id, node} ->
        {id, Map.put(node, :inbox, previous.nodes[id].inbox)}
      end)

    %{updated | nodes: nodes, messages: previous.messages}
  end

  defp ring_nodes(state, ring_id),
    do: Map.filter(state.nodes, fn {_id, node} -> node.ring_id == ring_id end)

  defp public_nodes(nodes) do
    nodes |> Map.values() |> Enum.sort_by(& &1.node_id) |> Enum.map(&public_node/1)
  end

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
      name: node_name(node),
      project: Map.get(node, :project),
      purpose: Map.get(node, :purpose),
      last_seen: node.last_seen,
      pending_messages: :queue.len(node.inbox)
    }
  end
end
