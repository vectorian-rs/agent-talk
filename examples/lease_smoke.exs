# mix run --no-start examples/lease_smoke.exs
# Own hub, short lease and ephemeral port; never connects to the trial server.
alias Anubis.Client
verify = fn condition, message -> if !condition, do: raise(message) end

verify.(
  not Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_talk)),
  "Run with mix run --no-start"
)

ttl_ms = 2000
Application.put_env(:agent_talk, :node_ttl_ms, ttl_ms)
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

expect_error = fn client, tool, args, code, expected ->
  case Client.call_tool(client, tool, args) do
    {:ok, %{is_error: true, result: result}} ->
      verify.(
        result["structuredContent"]["error"]["code"] == code,
        "Unexpected #{tool} error code"
      )

      verify.(
        Enum.any?(result["content"], &String.starts_with?(&1["text"], expected)),
        "Unexpected #{tool} error"
      )

    _ ->
      raise "Expected #{tool} failure (response omitted to protect credentials)"
  end
end

auth = fn node, fields -> Map.merge(%{node_id: node["node_id"], token: node["token"]}, fields) end

renew = fn client, node ->
  fresh = call.(client, "register_node", Map.take(node, ["node_id", "role", "token"]))

  verify.(
    fresh["node_id"] == node["node_id"] and fresh["token"] == node["token"] and
      fresh["ring_token"] == node["ring_token"],
    "Renewal changed identity or credentials"
  )

  verify.(fresh["expires_in_seconds"] == ttl_ms / 1000, "TTL mismatch")
  fresh
end

rejoin = fn client, old ->
  fresh = call.(client, "register_node", Map.take(old, ["role", "ring_token"]))

  verify.(
    fresh["node_id"] != old["node_id"] and fresh["ring_id"] == old["ring_id"],
    "Rejoin reused an ID or changed rings"
  )

  verify.(fresh["expires_in_seconds"] == ttl_ms / 1000, "Rejoin TTL mismatch")
  fresh
end

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
  pm["expires_in_seconds"] == 2 and is_binary(pm["onboarding_prompt_template"]),
  "PM onboarding mismatch"
)

workers =
  for client <- [AgentTalk.SmokeW1, AgentTalk.SmokeW2] do
    {client, call.(client, "register_node", %{role: "worker", ring_token: pm["ring_token"]})}
  end

exchange = fn pm, workers ->
  ids = Enum.map(workers, fn {_client, worker} -> worker["node_id"] end) |> Enum.sort()
  found = call.(pm_client, "list_nodes", auth.(pm, %{role: "worker"}))
  verify.(Enum.map(found["nodes"], & &1["node_id"]) == ids, "Ring discovery mismatch")

  sent =
    call.(
      pm_client,
      "communicate",
      auth.(pm, %{action: "send", to_role: "worker", message: "Task"})
    )

  verify.(sent["delivered_to"] == ids, "Ring broadcast mismatch")

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
  verify.(Enum.sort(Enum.map(inbox["messages"], & &1["from"])) == ids, "PM reply mismatch")
end

exchange.(pm, workers)
pm = renew.(pm_client, pm)

IO.puts(
  "PASS: PM created a ring; two independent clients joined, discovered and exchanged messages"
)

Process.sleep(ttl_ms + 200)
missing = "node is not registered or has expired; join again with role and ring_token"
expect_error.(pm_client, "list_nodes", auth.(pm, %{}), "expired", missing)

expect_error.(
  pm_client,
  "register_node",
  Map.take(pm, ["role", "node_id", "token"]),
  "expired",
  missing
)

old_pm = pm
pm = rejoin.(pm_client, pm)
expect_error.(pm_client, "communicate", auth.(old_pm, %{action: "receive"}), "expired", missing)

expect_error.(
  pm_client,
  "communicate",
  auth.(%{pm | "token" => old_pm["token"]}, %{action: "receive"}),
  "invalid_token",
  "invalid node token"
)

workers = Enum.map(workers, fn {client, old} -> {client, rejoin.(client, old)} end)

IO.puts(
  "PASS: idle expiry required fresh IDs; the invitation retained ring membership; stale credentials failed"
)

call.(
  pm_client,
  "communicate",
  auth.(pm, %{action: "send", to_role: "worker", message: "Uncollected"})
)

Process.sleep(div(ttl_ms, 2))
pm = renew.(pm_client, pm)
Process.sleep(div(ttl_ms, 2) + 200)
found = call.(pm_client, "list_nodes", auth.(pm, %{}))
verify.(Enum.map(found["nodes"], & &1["node_id"]) == [pm["node_id"]], "Worker expiry mismatch")
expired_worker = workers |> hd() |> elem(1)

expect_error.(
  pm_client,
  "communicate",
  auth.(pm, %{action: "send", to: [expired_worker["node_id"]], message: "Not delivered"}),
  "invalid_request",
  "unknown or expired recipients"
)

workers = Enum.map(workers, fn {client, old} -> {client, rejoin.(client, old)} end)

for {client, worker} <- workers do
  verify.(
    call.(client, "communicate", auth.(worker, %{action: "receive"}))["messages"] == [],
    "Expired inbox survived"
  )
end

exchange.(pm, workers)
IO.puts("PASS: expiry discarded queued messages; rejoining restored PM-to-workers delivery")

other_pm = call.(pm_client, "register_node", %{role: "pm"})

outsider =
  call.(AgentTalk.SmokeW2, "register_node", %{role: "worker", ring_token: other_pm["ring_token"]})

expect_error.(
  pm_client,
  "communicate",
  auth.(pm, %{action: "send", to: [outsider["node_id"]], message: "Cross-ring"}),
  "invalid_request",
  "unknown or expired recipients"
)

sent =
  call.(
    pm_client,
    "communicate",
    auth.(pm, %{action: "send", to_role: "all", message: "Ring only"})
  )

verify.(length(sent["delivered_to"]) == 2, "Broadcast crossed ring boundary")

verify.(
  call.(AgentTalk.SmokeW2, "communicate", auth.(outsider, %{action: "receive"}))["messages"] == [],
  "Other ring received a broadcast"
)

IO.puts("PASS: direct messages and broadcasts cannot cross ring boundaries; no tokens printed")
