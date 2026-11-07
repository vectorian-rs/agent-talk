# Run with: mix run examples/demo.exs
# To watch an already running server:
# AGENT_TALK_URL=http://127.0.0.1:4000 mix run --no-start examples/demo.exs
alias Anubis.Client

{:ok, _} = Application.ensure_all_started(:anubis_mcp)
Logger.configure(level: :info)
{:ok, _} = Finch.start_link(name: Anubis.Finch)

external_url = System.get_env("AGENT_TALK_URL")
base_url = external_url || "http://127.0.0.1:#{Application.fetch_env!(:agent_talk, :port)}"

suffix =
  if external_url,
    do: "-demo-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower),
    else: ""

pause = fn -> if external_url, do: Process.sleep(700) end

call = fn client, tool, args ->
  {:ok, response} = Client.call_tool(client, tool, args)
  if response.is_error, do: raise(inspect(response.result))
  response.result["structuredContent"]
end

agents = [
  {AgentTalk.DemoPM, "pm", "pm"},
  {AgentTalk.DemoBackend, "backend", "implementation"},
  {AgentTalk.DemoFrontend, "frontend", "implementation"}
]

nodes =
  Enum.map(agents, fn {client, id, role} ->
    id = id <> suffix

    {:ok, _} =
      Client.start_link(
        name: client,
        transport: {:streamable_http, base_url: base_url},
        client_info: %{"name" => id, "version" => "0.1.0"},
        capabilities: %{}
      )

    :ok = Client.await_ready(client)
    node = call.(client, "register_node", %{node_id: id, role: role})
    {client, %{node_id: id, token: node["token"]}}
  end)

[{pm, pm_auth} | workers] = nodes
IO.inspect(call.(pm, "list_nodes", %{}), label: "Connected agents")
pause.()

targets =
  if external_url,
    do: %{to: Enum.map(workers, fn {_client, auth} -> auth.node_id end)},
    else: %{to_role: "implementation"}

IO.inspect(
  call.(
    pm,
    "communicate",
    pm_auth
    |> Map.merge(targets)
    |> Map.merge(%{action: "send", message: "Implement your part of the feature."})
  ),
  label: "PM broadcasts"
)

for {client, auth} <- workers do
  pause.()

  IO.inspect(call.(client, "communicate", Map.put(auth, :action, "receive")),
    label: "#{auth.node_id} inbox"
  )

  call.(
    client,
    "communicate",
    Map.merge(auth, %{action: "send", to: [pm_auth.node_id], message: "#{auth.node_id}: done"})
  )
end

pause.()

IO.inspect(call.(pm, "communicate", Map.put(pm_auth, :action, "receive")),
  label: "PM receives replies"
)
