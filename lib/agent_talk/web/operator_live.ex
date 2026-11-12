defmodule AgentTalk.Web.OperatorLive do
  use Phoenix.LiveView, layout: false

  alias AgentTalk.Hub
  alias AgentTalk.Web.MessageText

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AgentTalk.PubSub, Hub.topic())

    {:ok,
     socket
     |> assign(
       party: "all",
       query: "",
       ring: nil,
       compose: "",
       review_date: Date.to_iso8601(Date.utc_today())
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:hub_updated, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("filter", %{"party" => party, "query" => query}, socket) do
    {:noreply, socket |> assign(party: party, query: query) |> filter_messages()}
  end

  def handle_event("select_ring", %{"ring" => ring}, socket) do
    if Enum.any?(socket.assigns.rings, &(&1.id == ring)) do
      {:noreply,
       socket |> assign(ring: ring, party: "all", query: "", compose: "") |> scope_ring()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("evict", %{"node_id" => node_id}, socket) do
    # The dashboard is the trusted local surface; eviction needs no token. On
    # success the hub's pubsub broadcast refreshes this and every open view; a
    # storage failure leaves the node in place and is surfaced, never crashing.
    case Hub.evict(node_id) do
      {:ok, _} -> {:noreply, socket}
      {:error, _code, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("clear_error", _params, socket), do: {:noreply, clear_flash(socket)}

  # Track the compose textarea so a concurrent refresh can't wipe a half-typed
  # message; the value is bound to @compose on every render.
  def handle_event("compose", %{"message" => message}, socket),
    do: {:noreply, assign(socket, :compose, message)}

  def handle_event("broadcast", %{"message" => message}, socket) do
    # Trusted local surface: broadcasting into the selected ring needs no token.
    # On success the hub's pubsub refresh re-renders every view and we clear the
    # box; a capacity or storage error is surfaced and the draft is kept.
    case socket.assigns.ring && Hub.broadcast(socket.assigns.ring, message) do
      {:ok, _} -> {:noreply, assign(socket, :compose, "")}
      {:error, _code, msg} -> {:noreply, put_flash(socket, :error, msg)}
      nil -> {:noreply, socket}
    end
  end

  defp refresh(socket) do
    {:ok, snapshot} = Hub.snapshot()
    rings = ring_options(snapshot)
    previous = socket.assigns[:ring]

    ring =
      if Enum.any?(rings, &(&1.id == previous)),
        do: previous,
        else: Enum.find_value(rings, & &1.id)

    socket
    |> assign(snapshot: snapshot, rings: rings, ring: ring)
    |> drop_stale_compose(previous, ring)
    |> scope_ring()
  end

  # A draft belongs to the ring it was typed in. If the selected ring changes —
  # including the fallback when that ring disappears — drop the draft so a
  # broadcast can never land in a ring the operator wasn't composing for.
  defp drop_stale_compose(socket, previous, ring) do
    if previous != nil and previous != ring, do: assign(socket, :compose, ""), else: socket
  end

  defp ring_options(snapshot) do
    nodes_by_ring = Enum.group_by(snapshot.nodes, & &1.ring_id)
    messages_by_ring = Enum.group_by(snapshot.messages, & &1.ring_id)

    (Map.keys(nodes_by_ring) ++ Map.keys(messages_by_ring))
    |> Enum.uniq()
    |> Enum.map(fn id ->
      nodes = nodes_by_ring |> Map.get(id, []) |> Enum.sort_by(&(&1.role != "pm"))

      project =
        Enum.find_value(nodes, & &1.project) ||
          Enum.find_value(Map.get(messages_by_ring, id, []), & &1.project)

      %{id: id, label: if(project, do: "#{project} · #{id}", else: id)}
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp scope_ring(socket) do
    snapshot = socket.assigns.snapshot
    ring = socket.assigns.ring

    nodes =
      snapshot.nodes
      |> Enum.filter(&(&1.ring_id == ring))
      |> Enum.sort_by(&{&1.role != "pm", &1.name, &1.node_id})

    messages = Enum.filter(snapshot.messages, &(&1.ring_id == ring))

    # Message text is immutable once sent; parse links once per message id.
    # Keyed over the whole snapshot so switching rings keeps cached entries.
    cache = socket.assigns[:parts] || %{}
    parts = Map.new(snapshot.messages, &{&1.id, cache[&1.id] || MessageText.parts(&1.message)})

    labels =
      messages
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn event, labels ->
        labels
        |> Map.put(event.from, event.from_name)
        |> Map.merge(event.to_names)
      end)
      |> Map.merge(Map.new(nodes, &{&1.node_id, &1.name}))

    socket
    |> assign(
      nodes: nodes,
      messages: messages,
      labels: labels,
      parts: parts,
      parties: Enum.sort_by(Map.keys(labels), &{labels[&1], &1})
    )
    |> filter_messages()
  end

  defp filter_messages(socket) do
    party = socket.assigns.party
    query = String.downcase(String.trim(socket.assigns.query))

    visible =
      Enum.filter(socket.assigns.messages, fn event ->
        (party == "all" or event.from == party or party in event.to) and
          (query == "" or
             String.contains?(
               String.downcase(
                 event.message <>
                   " " <>
                   Enum.map_join([event.from | event.to], " ", fn id ->
                     id <> " " <> Map.get(socket.assigns.labels, id, id)
                   end)
               ),
               query
             ))
      end)

    assign(socket, :visible_messages, visible)
  end

  defp clock(iso8601), do: String.slice(iso8601, 11, 8)

  defp ring_label(rings, id) do
    case Enum.find(rings, &(&1.id == id)) do
      %{label: label} -> label
      _ -> id
    end
  end

  defp role_name("pm"), do: "PM"
  defp role_name(role), do: String.capitalize(role)

  defp delivery(event) do
    case length(event.received_by) do
      0 -> if(event.pending_to == [], do: "Not collected", else: "Queued")
      count when count == length(event.to) -> "Collected"
      count -> "Collected #{count}/#{length(event.to)}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="operator-shell">
      <header class="operator-header wrap">
        <a class="operator-brand" href="/" aria-label="Agent Talk home">
          <span class="brand-mark" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
              <path d="M4 5h12v9H9l-4 3v-3H4z" /><path d="M18 9h2v12l-4-3h-5v-2" />
            </svg>
          </span>
          <span>agent<span class="brand-light">talk</span></span>
        </a>
        <div class="header-actions">
          <span class="small-label operator-label">Operator console</span>
          <div id="connection-status" phx-hook="ConnectionStatus" phx-update="ignore" class="connection-status is-connecting" role="status" aria-label="Operator connection">
            <span class="connection-dot" aria-hidden="true"></span>
            <span data-connection-label>Connecting</span>
          </div>
          <button id="theme-toggle" class="theme-button" type="button" aria-label="Switch color theme" title="Switch color theme">
            <svg class="theme-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
              <path d="M20.5 13a8.5 8.5 0 0 1-9.5-9.5A8.5 8.5 0 1 0 20.5 13Z" />
            </svg>
            <svg class="theme-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
              <circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" />
            </svg>
          </button>
        </div>
      </header>

      <p
        :if={Phoenix.Flash.get(@flash, :error)}
        id="operator-error"
        class="operator-error"
        role="alert"
        phx-click="clear_error"
        title="Dismiss"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </p>

      <main id="main" class="wrap operator-main">
        <section class="console-heading" aria-labelledby="console-title">
          <div>
            <p class="eyebrow">MCP monitoring</p>
            <h1 id="console-title">Agent messages</h1>
            <p class="console-intro">Message routing, inbox status, and agent presence.</p>
          </div>
          <dl class="console-stats">
            <div><dt>Active registrations</dt><dd id="agent-count">{length(@nodes)}</dd></div>
            <div><dt>Messages retained</dt><dd><span id="message-count">{length(@messages)}</span><span class="stat-limit"> / {@snapshot.history_limit}</span></dd></div>
          </dl>
        </section>

        <div class="console-grid">
          <aside class="agents-panel" aria-labelledby="agents-title">
            <div id="ring-selector" class="ring-selector" role="group" aria-label="Ring">
              <span class="small-label">Ring</span>
              <p :if={@rings == []} id="ring-empty" class="ring-empty">No rings</p>
              <div :if={@rings != []} id="ring-select" class="ring-chips">
                <button
                  :for={ring <- @rings}
                  type="button"
                  class={["ring-chip", @ring == ring.id && "is-selected"]}
                  phx-click="select_ring"
                  phx-value-ring={ring.id}
                  aria-pressed={@ring == ring.id}
                  title={ring.label}
                >{ring.label}</button>
              </div>
            </div>
            <form
              :if={@ring && @nodes != []}
              id="operator-broadcast"
              class="operator-broadcast"
              phx-change="compose"
              phx-submit="broadcast"
            >
              <label for="broadcast-message" class="small-label">Broadcast to ring</label>
              <textarea
                id="broadcast-message"
                name="message"
                rows="2"
                placeholder="Message every agent in this ring…"
                phx-debounce="150"
                autocomplete="off"
              >{@compose}</textarea>
              <button
                type="submit"
                class="broadcast-send"
                disabled={String.trim(@compose) == ""}
                data-confirm={"Broadcast to all #{length(@nodes)} agent(s) in #{ring_label(@rings, @ring)}?"}
              >
                Broadcast
              </button>
            </form>
            <div class="panel-heading">
              <h2 id="agents-title">Registered agents</h2><span class="count-label">{length(@nodes)}</span>
            </div>
            <div :if={@nodes == []} id="empty-agents" class="empty-agents">
              <span class="empty-node" aria-hidden="true">+</span>
              <p>No active registrations.</p>
              <p class="muted">Agents are listed after registration.</p>
            </div>
            <ul :if={@nodes != []} id="agent-list" class="agent-list">
              <li :for={node <- @nodes} id={"agent-#{node.node_id}"} class="agent-item">
                <span class={["agent-avatar", node.role == "pm" && "avatar-pm"]} aria-hidden="true">
                  {String.upcase(String.first(node.role))}
                </span>
                <div class="agent-details">
                  <p class="agent-name">{node.name}</p>
                  <p class="agent-role">{role_name(node.role)} · {node.node_id}</p>
                  <p :if={node.purpose} class="agent-purpose" title="Advertised purpose">{node.purpose}</p>
                  <p class="agent-pending">{node.pending_messages} in inbox</p>
                  <p class="agent-activity">
                    Last activity <time datetime={node.last_seen} title={node.last_seen}>{clock(node.last_seen)} UTC</time>
                  </p>
                </div>
                <span class="agent-online" aria-label="Registration active"></span>
                <button
                  type="button"
                  class="agent-evict"
                  phx-click="evict"
                  phx-value-node_id={node.node_id}
                  data-confirm={"Evict #{node.name}? This expires its registration and discards #{node.pending_messages} queued message(s). An active agent can rejoin automatically."}
                  title="Force-expire this node"
                >
                  Evict
                </button>
              </li>
            </ul>
            <div class="presence-note">
              <span class="small-label">Registration lease</span>
              <p>Discovery, messaging, and registration renew the caller's lease.</p>
            </div>
          </aside>

          <section class="messages-panel" aria-labelledby="messages-title">
            <div class="panel-heading messages-heading">
              <div><h2 id="messages-title">Message log</h2><p class="stream-caption">Newest first · UTC</p></div>
              <span class="small-label retention-label">Last {@snapshot.history_limit}</span>
            </div>
            <form id="message-filters" phx-change="filter" class="message-filters" role="search" aria-label="Filter messages">
              <label class="search-field">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 4 4" /></svg>
                <span class="sr-only">Search messages</span>
                <input name="query" type="search" value={@query} placeholder="Search messages…" phx-debounce="150" autocomplete="off" />
              </label>
              <label class="party-field">
                <span class="sr-only">Filter by agent</span>
                <select name="party" aria-label="Filter by agent">
                  <option value="all" selected={@party == "all"}>All agents</option>
                  <option :for={party <- Enum.uniq([@party | @parties]) |> Enum.reject(&(&1 == "all"))} value={party} selected={@party == party}>{Map.get(@labels, party, party)}</option>
                </select>
              </label>
            </form>

            <form :if={@snapshot.history_persistent} id="history-export" class="history-export" action="/history/export" method="get">
              <label for="history-date" class="small-label">Conversation archive · UTC</label>
              <div class="history-export-row">
                <input id="history-date" name="date" type="date" value={@review_date} required />
                <select name="ring" aria-label="Archive ring scope">
                  <option :if={@ring} value={@ring} selected>Selected ring</option>
                  <option value="" selected={is_nil(@ring)}>All rings</option>
                </select>
                <button type="submit">Download day (Markdown)</button>
              </div>
            </form>

            <div :if={@messages == []} id="empty-messages" class="empty-messages chart-panel">
              <div class="empty-conversation" aria-hidden="true"><span>SENDER</span><span class="empty-route">→</span><span>RECIPIENTS</span></div>
              <h3>No messages recorded.</h3>
              <p>Messages are listed when an agent sends them.</p>
            </div>
            <div :if={@messages != [] and @visible_messages == []} id="no-matches" class="no-matches">
              <h3>No matching messages.</h3><p>Change the search query or agent filter.</p>
            </div>

            <ol id="message-stream" class="message-stream" aria-label="Recent messages" aria-live="polite" aria-relevant="additions">
              <li :for={event <- @visible_messages} id={"message-#{event.id}"} class="message-item">
                <div class="message-meta">
                  <div class="message-route">
                    <span class={["party-name", event.from_role == "pm" && "party-pm"]} title={event.from}>{Map.get(@labels, event.from, event.from)}</span>
                    <span class="route-arrow" aria-label="to">→</span>
                    <span class="recipient-list"><span :for={recipient <- event.to} class="recipient-name" title={recipient}>{Map.get(@labels, recipient, recipient)}</span></span>
                  </div>
                  <time datetime={event.sent_at}>{clock(event.sent_at)}</time>
                </div>
                <p class="message-body"><%= for part <- @parts[event.id] do %><a :if={part.url} href={part.url} target="_blank" rel="noopener noreferrer">{part.text}</a>{if is_nil(part.url), do: part.text}<% end %></p>
                <div class="message-footer">
                  <span class="small-label message-kind">{event.ring_id} · {if length(event.to) > 1, do: "Broadcast · #{length(event.to)} recipients", else: "Direct message"}<span :if={event.reply_to} class="reply-ref" title="Answers an earlier message"> · ↩ {event.reply_to}</span></span>
                  <span class={["delivery-status", event.received_by != [] && "delivery-collected"]} title="Collected means a recipient fetched the message from its inbox.">
                    <span aria-hidden="true">{if event.received_by == [], do: "○", else: "✓"}</span> {delivery(event)}
                  </span>
                </div>
              </li>
            </ol>
            <p :if={@messages != []} class="stream-end">Showing {length(@visible_messages)} of {length(@messages)} retained messages.</p>
          </section>
        </div>
        <footer class="operator-footer"><span>AgentTalk</span><span>{if @snapshot.history_persistent, do: "Archive: SQLite", else: "Log: memory only"} · live window: {@snapshot.history_limit}</span></footer>
      </main>
    </div>
    """
  end
end
