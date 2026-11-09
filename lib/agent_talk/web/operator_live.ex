defmodule AgentTalk.Web.OperatorLive do
  use Phoenix.LiveView, layout: false

  alias AgentTalk.Hub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AgentTalk.PubSub, Hub.topic())
    {:ok, socket |> assign(party: "all", query: "", ring: nil) |> refresh()}
  end

  @impl true
  def handle_info(:hub_updated, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("filter", %{"party" => party, "query" => query}, socket) do
    {:noreply, socket |> assign(party: party, query: query) |> filter_messages()}
  end

  def handle_event("select_ring", %{"ring" => ring}, socket) do
    if Enum.any?(socket.assigns.rings, &(&1.id == ring)) do
      {:noreply, socket |> assign(ring: ring, party: "all", query: "") |> scope_ring()}
    else
      {:noreply, socket}
    end
  end

  defp refresh(socket) do
    {:ok, snapshot} = Hub.snapshot()
    rings = ring_options(snapshot)
    previous = socket.assigns[:ring]

    ring =
      if Enum.any?(rings, &(&1.id == previous)) do
        previous
      else
        case List.first(rings) do
          nil -> nil
          first -> first.id
        end
      end

    socket
    |> assign(
      snapshot: snapshot,
      rings: rings,
      ring: ring,
      history_limit: snapshot.history_limit
    )
    |> scope_ring()
  end

  defp ring_options(snapshot) do
    (Enum.map(snapshot.nodes, & &1.ring_id) ++ Enum.map(snapshot.messages, & &1.ring_id))
    |> Enum.uniq()
    |> Enum.map(fn id ->
      nodes =
        snapshot.nodes |> Enum.filter(&(&1.ring_id == id)) |> Enum.sort_by(&(&1.role != "pm"))

      project =
        Enum.find_value(nodes, &Map.get(&1, :project)) ||
          Enum.find_value(snapshot.messages, fn event ->
            if event.ring_id == id, do: Map.get(event, :project)
          end)

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
      |> Enum.sort_by(&{&1.role != "pm", Map.get(&1, :name) || &1.node_id, &1.node_id})

    messages = Enum.filter(snapshot.messages, &(&1.ring_id == ring))

    labels =
      messages
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn event, labels ->
        labels
        |> Map.put(event.from, Map.get(event, :from_name, event.from))
        |> Map.merge(Map.get(event, :to_names, %{}))
      end)
      |> Map.merge(Map.new(nodes, &{&1.node_id, Map.get(&1, :name) || &1.node_id}))

    socket
    |> assign(
      nodes: nodes,
      messages: messages,
      labels: labels,
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
  defp role_name("pm"), do: "PM"
  defp role_name(role), do: String.capitalize(role)

  defp delivery(event) do
    case length(event.received_by) do
      0 -> "Queued"
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

      <main id="main" class="wrap operator-main">
        <section class="console-heading" aria-labelledby="console-title">
          <div>
            <p class="eyebrow">MCP monitoring</p>
            <h1 id="console-title">Agent messages</h1>
            <p class="console-intro">Message routing, inbox status, and agent presence.</p>
          </div>
          <dl class="console-stats">
            <div><dt>Active registrations</dt><dd id="agent-count">{length(@nodes)}</dd></div>
            <div><dt>Messages retained</dt><dd><span id="message-count">{length(@messages)}</span><span class="stat-limit"> / {@history_limit}</span></dd></div>
          </dl>
        </section>

        <div class="console-grid">
          <aside class="agents-panel" aria-labelledby="agents-title">
            <form id="ring-selector" phx-change="select_ring" class="ring-selector">
              <label for="ring-select" class="small-label">Ring</label>
              <select id="ring-select" name="ring" disabled={@rings == []}>
                <option :if={@rings == []} value="">No rings</option>
                <option :for={ring <- @rings} value={ring.id} selected={@ring == ring.id}>{ring.label}</option>
              </select>
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
                  <p class="agent-pending">{node.pending_messages} in inbox</p>
                  <p class="agent-activity">
                    Last activity <time datetime={node.last_seen} title={node.last_seen}>{clock(node.last_seen)} UTC</time>
                  </p>
                </div>
                <span class="agent-online" aria-label="Registration active"></span>
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
              <span class="small-label retention-label">Last {@history_limit}</span>
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
                <p class="message-body"><%= for part <- AgentTalk.Web.MessageText.parts(event.message) do %><a :if={part.url} href={part.url} target="_blank" rel="noopener noreferrer">{part.text}</a>{if is_nil(part.url), do: part.text}<% end %></p>
                <div class="message-footer">
                  <span class="small-label message-kind">{event.ring_id} · {if length(event.to) > 1, do: "Broadcast · #{length(event.to)} recipients", else: "Direct message"}</span>
                  <span class={["delivery-status", event.received_by != [] && "delivery-collected"]} title="Collected means a recipient fetched the message from its inbox.">
                    <span aria-hidden="true">{if event.received_by == [], do: "○", else: "✓"}</span> {delivery(event)}
                  </span>
                </div>
              </li>
            </ol>
            <p :if={@messages != []} class="stream-end">Showing {length(@visible_messages)} of {length(@messages)} retained messages.</p>
          </section>
        </div>
        <footer class="operator-footer"><span>AgentTalk</span><span>Shared log: memory only · limit: {@history_limit}</span></footer>
      </main>
    </div>
    """
  end
end
