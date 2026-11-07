# mix run --no-start examples/lease_smoke.exs
# Own hub and ephemeral port; never connects to the trial server.
alias Anubis.Client

verify = fn condition, message -> if !condition, do: raise(message) end

verify.(
  not Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_talk)),
  "Run with mix run --no-start"
)

# Override only this isolated process; leave the operator's config files untouched.
ttl_ms = 2000
Application.put_env(:agent_talk, :node_ttl_ms, ttl_ms)
Logger.configure(level: :warning)
Application.put_env(:agent_talk, :http_enabled, false)
{:ok, _} = Application.ensure_all_started(:agent_talk)
{:ok, _} = Finch.start_link(name: Anubis.Finch)

{:ok, listener} =
  Bandit.start_link(plug: AgentTalk.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

{:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
url = "http://127.0.0.1:#{port}"

call = fn client, tool, args ->
  case Client.call_tool(client, tool, args) do
    {:ok, %{is_error: false, result: result}} -> result["structuredContent"]
    _ -> raise "#{tool} failed (response omitted to protect credentials)"
  end
end

expect_error = fn client, tool, args, expected ->
  case Client.call_tool(client, tool, args) do
    {:ok, %{is_error: true, result: result}} ->
      verify.(Enum.any?(result["content"], &(&1["text"] == expected)), "Unexpected #{tool} error")

    _ ->
      raise "Expected #{tool} failure (response omitted to protect credentials)"
  end
end

auth = fn node, fields ->
  Map.merge(%{node_id: node["node_id"], token: node["token"]}, fields)
end

renew = fn client, node ->
  fresh = call.(client, "register_node", Map.take(node, ["node_id", "role", "token"]))
  verify.(fresh["expires_in_seconds"] == ttl_ms / 1000, "Configured TTL mismatch")
  fresh
end

renew_workers = fn workers ->
  Enum.map(workers, fn {client, old} ->
    fresh = renew.(client, old)
    verify.(fresh["token"] != old["token"], "Expired worker kept its token")
    {client, fresh}
  end)
end

agents = [
  {AgentTalk.SmokePM, "celeratax-pm", "pm"},
  {AgentTalk.SmokeW1, "celeratax-w-1", "implementation"},
  {AgentTalk.SmokeW2, "celeratax-w-2", "implementation"}
]

# Connect all clients before starting any short node lease.
for {client, id, _role} <- agents do
  {:ok, _} =
    Client.start_link(
      name: client,
      transport: {:streamable_http, base_url: url},
      client_info: %{"name" => id, "version" => "0.1.0"},
      capabilities: %{}
    )

  :ok = Client.await_ready(client)
end

[{pm_client, pm} | workers] =
  Enum.map(agents, fn {client, id, role} ->
    node = call.(client, "register_node", %{node_id: id, role: role})
    verify.(node["expires_in_seconds"] == ttl_ms / 1000, "Configured TTL mismatch")
    {client, node}
  end)

exchange = fn pm, workers ->
  recipients = Enum.map(workers, fn {_client, node} -> node["node_id"] end)

  sent =
    call.(pm_client, "communicate", auth.(pm, %{action: "send", to: recipients, message: "Task"}))

  verify.(sent["delivered_to"] == recipients, "Fan-out mismatch")

  for {client, worker} <- workers do
    inbox = call.(client, "communicate", auth.(worker, %{action: "receive"}))

    verify.(
      Enum.map(inbox["messages"], & &1["id"]) == [sent["message_id"]],
      "Worker delivery mismatch"
    )

    call.(
      client,
      "communicate",
      auth.(worker, %{action: "send", to: [pm["node_id"]], message: "Ready"})
    )
  end

  inbox = call.(pm_client, "communicate", auth.(pm, %{action: "receive"}))
  senders = Enum.map(inbox["messages"], & &1["from"]) |> Enum.sort()
  verify.(senders == ["celeratax-w-1", "celeratax-w-2"], "PM reply mismatch")
end

exchange.(pm, workers)
renewed = renew.(pm_client, pm)
verify.(renewed["token"] == pm["token"], "Active renewal changed the token")
pm = renewed
IO.puts("PASS: three MCP clients registered, exchanged messages and renewed; TTL matched")

Process.sleep(ttl_ms + 200)
verify.(call.(pm_client, "list_nodes", %{})["nodes"] == [], "Idle nodes did not expire")

expect_error.(
  pm_client,
  "communicate",
  auth.(pm, %{action: "receive"}),
  "node is not registered or has expired; call register_node"
)

old_pm = pm
pm = renew.(pm_client, pm)
verify.(pm["token"] != old_pm["token"], "Expired registration kept its token")
expect_error.(pm_client, "communicate", auth.(old_pm, %{action: "receive"}), "invalid node token")

expect_error.(
  pm_client,
  "register_node",
  Map.take(old_pm, ["node_id", "role", "token"]),
  "node_id is already registered; its token is required to renew it"
)

workers = renew_workers.(workers)

IO.puts(
  "PASS: open MCP sessions did not prevent expiry; replacement tokens rejected stale credentials"
)

call.(
  pm_client,
  "communicate",
  auth.(pm, %{action: "send", to: ["celeratax-w-1", "celeratax-w-2"], message: "Uncollected"})
)

Process.sleep(div(ttl_ms, 2))
pm = renew.(pm_client, pm)
Process.sleep(div(ttl_ms, 2) + 200)
nodes = call.(pm_client, "list_nodes", %{})["nodes"]
verify.(Enum.map(nodes, & &1["node_id"]) == [pm["node_id"]], "Idle worker expiry mismatch")

expect_error.(
  pm_client,
  "communicate",
  auth.(pm, %{action: "send", to: ["celeratax-w-1"], message: "Not delivered"}),
  "unknown or expired recipients: celeratax-w-1"
)

# Keep each complete successful registration response as the new credential source.
workers = renew_workers.(workers)

for {client, worker} <- workers do
  inbox = call.(client, "communicate", auth.(worker, %{action: "receive"}))
  verify.(inbox["messages"] == [], "Expired worker retained its old inbox")
end

exchange.(pm, workers)
IO.puts("PASS: expiry discarded queued messages; re-registration restored delivery")
