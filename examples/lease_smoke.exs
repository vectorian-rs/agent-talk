# mix run --no-start examples/lease_smoke.exs
# Legacy filename; verifies durable membership and expiring presence in isolation.
alias Anubis.Client
verify = fn condition, message -> if !condition, do: raise(message) end

verify.(
  not Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_talk)),
  "Run with mix run --no-start"
)

presence_ms = 1000
Application.put_env(:agent_talk, :presence_timeout_ms, presence_ms)
Application.put_env(:agent_talk, :http_enabled, false)
Application.put_env(:agent_talk, :membership_file, nil)
Application.put_env(:agent_talk, :history_file, nil)
Logger.configure(level: :warning)
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

expect_error = fn client, tool, args, code ->
  case Client.call_tool(client, tool, args) do
    {:ok, %{is_error: true, result: result}} ->
      verify.(
        result["structuredContent"]["error"]["code"] == code,
        "Unexpected #{tool} error code"
      )

    _ ->
      raise "Expected #{tool} failure (response omitted to protect credentials)"
  end
end

auth = fn node, fields -> Map.merge(%{node_id: node["node_id"], token: node["token"]}, fields) end

for name <- [AgentTalk.SmokePM, AgentTalk.SmokeW1, AgentTalk.SmokeW2] do
  {:ok, _} =
    Client.start_link(
      name: name,
      transport: {:streamable_http, base_url: url},
      client_info: %{"name" => to_string(name), "version" => "1"},
      capabilities: %{}
    )

  :ok = Client.await_ready(name)
end

pm_client = AgentTalk.SmokePM
pm = call.(pm_client, "register_node", %{role: "pm"})

verify.(
  is_nil(pm["expires_in_seconds"]) and pm["presence_timeout_seconds"] == 1,
  "Membership/presence contract mismatch"
)

workers =
  for client <- [AgentTalk.SmokeW1, AgentTalk.SmokeW2] do
    {client, call.(client, "register_node", %{role: "worker", ring_token: pm["ring_token"]})}
  end

ids = workers |> Enum.map(fn {_, worker} -> worker["node_id"] end) |> Enum.sort()

sent =
  call.(
    pm_client,
    "communicate",
    auth.(pm, %{action: "send", to_role: "worker", message: "Queued before offline"})
  )

verify.(sent["delivered_to"] == ids, "Broadcast mismatch")
Process.sleep(presence_ms + 200)
found = call.(pm_client, "list_nodes", auth.(pm, %{role: "worker"}))
verify.(Enum.map(found["nodes"], & &1["node_id"]) == ids, "Offline membership disappeared")
verify.(Enum.all?(found["nodes"], &(not &1["online"])), "Presence did not go offline")
IO.puts("PASS: idle agents went offline without losing membership or queued mail")

for {client, worker} <- workers do
  returned = call.(client, "register_node", Map.take(worker, ["role", "node_id", "token"]))

  verify.(
    returned["node_id"] == worker["node_id"] and returned["token"] == worker["token"],
    "Returning changed identity or credentials"
  )

  inbox = call.(client, "communicate", auth.(worker, %{action: "receive"}))

  verify.(
    Enum.map(inbox["messages"], & &1["id"]) == [sent["message_id"]],
    "Offline queued mail was lost"
  )

  call.(
    client,
    "communicate",
    auth.(worker, %{action: "send", to: [pm["node_id"]], message: "Returned"})
  )
end

replies = call.(pm_client, "communicate", auth.(pm, %{action: "receive"}))
verify.(Enum.sort(Enum.map(replies["messages"], & &1["from"])) == ids, "Return exchange mismatch")
IO.puts("PASS: original identities returned, collected mail and replied to the PM")

other_pm = call.(pm_client, "register_node", %{role: "pm"})

outsider =
  call.(AgentTalk.SmokeW2, "register_node", %{role: "worker", ring_token: other_pm["ring_token"]})

expect_error.(
  pm_client,
  "communicate",
  auth.(pm, %{action: "send", to: [outsider["node_id"]], message: "Cross-ring"}),
  "invalid_request"
)

expect_error.(pm_client, "list_nodes", %{node_id: pm["node_id"], token: "wrong"}, "invalid_token")
IO.puts("PASS: ring isolation and private-node authentication remain enforced")

{client, worker} = hd(workers)
{:ok, %{evicted: true}} = AgentTalk.Hub.evict(worker["node_id"])
expect_error.(client, "list_nodes", auth.(worker, %{}), "not_registered")

expect_error.(
  client,
  "register_node",
  Map.take(worker, ["role", "node_id", "token"]),
  "not_registered"
)

IO.puts("PASS: explicit eviction invalidated the old identity; no tokens printed")
