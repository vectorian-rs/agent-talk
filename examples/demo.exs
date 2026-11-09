# Isolated: mix run --no-start examples/demo.exs
# Operator UI: mix run --no-start examples/demo.exs --url http://127.0.0.1:4000
alias Anubis.Client

{options, _args} = OptionParser.parse!(System.argv(), strict: [url: :string, config: :string])
external_url = options[:url]
Logger.configure(level: :warning)

base_url =
  if external_url do
    {:ok, _} = Application.ensure_all_started(:anubis_mcp)
    external_url
  else
    Application.put_env(:agent_talk, :http_enabled, false)
    Application.put_env(:agent_talk, :membership_file, nil)
    {:ok, _} = Application.ensure_all_started(:agent_talk)

    {:ok, listener} =
      Bandit.start_link(plug: AgentTalk.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}"
  end

{:ok, _} = Finch.start_link(name: Anubis.Finch)

call = fn client, tool, args ->
  case Client.call_tool(client, tool, args) do
    {:ok, %{is_error: false, result: result}} -> result["structuredContent"]
    _ -> raise "#{tool} failed (response omitted to protect credentials)"
  end
end

auth = fn node, fields -> Map.merge(%{node_id: node["node_id"], token: node["token"]}, fields) end
pause = fn -> if external_url, do: Process.sleep(700) end

for name <- [AgentTalk.DemoPM, AgentTalk.DemoW1, AgentTalk.DemoW2] do
  {:ok, _} =
    Client.start_link(
      name: name,
      transport: {:streamable_http, base_url: base_url},
      client_info: %{"name" => to_string(name), "version" => "1"},
      capabilities: %{}
    )

  :ok = Client.await_ready(name)
end

# Keep complete responses in memory; never print node or invitation tokens.
pm = call.(AgentTalk.DemoPM, "register_node", %{role: "pm"})

workers =
  for name <- [AgentTalk.DemoW1, AgentTalk.DemoW2] do
    {name, call.(name, "register_node", %{role: "worker", ring_token: pm["ring_token"]})}
  end

IO.inspect(call.(AgentTalk.DemoPM, "list_nodes", auth.(pm, %{})), label: "Ring members")
pause.()

IO.inspect(
  call.(
    AgentTalk.DemoPM,
    "communicate",
    auth.(pm, %{action: "send", to_role: "worker", message: "Implement your part of the feature."})
  ),
  label: "PM broadcasts within its ring"
)

for {name, worker} <- workers do
  pause.()

  IO.inspect(call.(name, "communicate", auth.(worker, %{action: "receive"})),
    label: "#{worker["node_id"]} inbox"
  )

  call.(
    name,
    "communicate",
    auth.(worker, %{action: "send", to: [pm["node_id"]], message: "#{worker["node_id"]}: done"})
  )
end

pause.()

IO.inspect(call.(AgentTalk.DemoPM, "communicate", auth.(pm, %{action: "receive"})),
  label: "PM receives replies"
)
