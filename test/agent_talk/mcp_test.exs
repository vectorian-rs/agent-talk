defmodule AgentTalk.MCPTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup_all do
    start_supervised!({Finch, name: Anubis.Finch})

    server =
      start_supervised!(
        {Bandit, plug: AgentTalk.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}"}
  end

  test "real MCP clients discover exactly three tools and exchange messages", %{url: url} do
    for name <- [AgentTalk.TestPM, AgentTalk.TestBackend, AgentTalk.TestFrontend] do
      start_supervised!(
        {Anubis.Client,
         name: name,
         transport: {:streamable_http, base_url: url},
         client_info: %{"name" => to_string(name), "version" => "0.1.0"},
         capabilities: %{}}
      )

      assert :ok = Anubis.Client.await_ready(name)
    end

    assert {:ok, response} = Anubis.Client.list_tools(AgentTalk.TestPM)

    assert Enum.sort(Enum.map(response.result["tools"], & &1["name"])) ==
             ["communicate", "list_nodes", "register_node"]

    pm = call(AgentTalk.TestPM, "register_node", %{node_id: "test-pm", role: "pm"})

    backend =
      call(AgentTalk.TestBackend, "register_node", %{
        node_id: "test-backend",
        role: "implementation"
      })

    frontend =
      call(AgentTalk.TestFrontend, "register_node", %{
        node_id: "test-frontend",
        role: "implementation"
      })

    nodes = call(AgentTalk.TestPM, "list_nodes", %{})

    assert Enum.map(nodes["nodes"], & &1["node_id"]) == [
             "test-backend",
             "test-frontend",
             "test-pm"
           ]

    sent =
      call(
        AgentTalk.TestPM,
        "communicate",
        auth(pm, %{action: "send", to_role: "implementation", message: "Build it"})
      )

    assert sent["delivered_to"] == ["test-backend", "test-frontend"]

    for {client, node} <- [{AgentTalk.TestBackend, backend}, {AgentTalk.TestFrontend, frontend}] do
      assert %{"messages" => [%{"from" => "test-pm", "message" => "Build it"}]} =
               call(client, "communicate", auth(node, %{action: "receive"}))
    end

    call(
      AgentTalk.TestBackend,
      "communicate",
      auth(backend, %{action: "send", to: ["test-pm"], message: "Done"})
    )

    assert %{"messages" => [%{"from" => "test-backend", "message" => "Done"}]} =
             call(AgentTalk.TestPM, "communicate", auth(pm, %{action: "receive"}))

    assert {:error, _} =
             Anubis.Client.call_tool(AgentTalk.TestPM, "register_node", %{node_id: "invalid"})

    assert {:error, _} =
             Anubis.Client.call_tool(AgentTalk.TestPM, "communicate", %{
               action: "unknown",
               node_id: "test-pm",
               token: pm["token"]
             })
  end

  test "legacy MCP clients can initialize and list tools", %{url: url} do
    response =
      post(url, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "legacy-test", version: "1"}
        }
      })

    assert response.status == 200
    assert decode(response.body)["result"]["protocolVersion"] == "2025-11-25"
    session = List.keyfind(response.headers, "mcp-session-id", 0) |> elem(1)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", "2025-11-25"}]

    initialized = post(url, %{jsonrpc: "2.0", method: "notifications/initialized"}, headers)
    assert initialized.status == 202

    response = post(url, %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}}, headers)
    assert response.status == 200
    assert length(decode(response.body)["result"]["tools"]) == 3
  end

  test "rejects foreign browser origins", %{url: url} do
    response =
      post(url, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, [
        {"origin", "https://example.com"}
      ])

    assert response.status == 403
  end

  defp call(client, tool, args) do
    assert {:ok, response} = Anubis.Client.call_tool(client, tool, args)
    refute response.is_error, inspect(response.result)
    response.result["structuredContent"]
  end

  defp auth(node, fields),
    do: Map.merge(%{node_id: node["node_id"], token: node["token"]}, fields)

  defp post(url, body, headers \\ []) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"} | headers
    ]

    request = Finch.build(:post, url <> "/mcp", headers, Jason.encode!(body))
    {:ok, response} = Finch.request(request, Anubis.Finch)
    response
  end

  defp decode("{" <> _ = body), do: Jason.decode!(body)

  defp decode(body) do
    body
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "data: "))
    |> String.replace_prefix("data: ", "")
    |> Jason.decode!()
  end
end
