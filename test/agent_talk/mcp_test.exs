defmodule AgentTalk.MCPTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  setup_all do
    start_supervised!({Finch, name: Anubis.Finch})

    listener =
      start_supervised!(
        {Bandit, plug: AgentTalk.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    %{url: "http://127.0.0.1:#{port}"}
  end

  test "three MCP clients create a ring, join from the invitation, discover and exchange messages",
       %{url: url} do
    for name <- [AgentTalk.TestPM, AgentTalk.TestW1, AgentTalk.TestW2], do: client(name, url)
    assert {:ok, tools} = Anubis.Client.list_tools(AgentTalk.TestPM)

    assert Enum.sort(Enum.map(tools.result["tools"], & &1["name"])) == [
             "communicate",
             "list_nodes",
             "register_node"
           ]

    schema = Enum.find(tools.result["tools"], &(&1["name"] == "register_node"))["inputSchema"]
    assert "role" in schema["required"]
    refute "node_id" in schema["required"]
    refute "ring_token" in schema["required"]
    refute Map.has_key?(schema["properties"]["role"], "enum")

    pm = call(AgentTalk.TestPM, "register_node", %{role: "pm"})
    assert pm["onboarding_prompt_template"] =~ "<RING_TOKEN>"

    workers =
      for name <- [AgentTalk.TestW1, AgentTalk.TestW2] do
        {name, call(name, "register_node", %{role: "worker", ring_token: pm["ring_token"]})}
      end

    ids = Enum.map(workers, fn {_client, node} -> node["node_id"] end) |> Enum.sort()
    nodes = call(AgentTalk.TestPM, "list_nodes", auth(pm, %{role: "worker"}))
    assert nodes["ring_id"] == pm["ring_id"]
    assert nodes["inbox"] == %{"pending_messages" => 0, "next_message_id" => nil}
    assert Enum.map(nodes["nodes"], & &1["node_id"]) == ids

    assert Enum.all?(
             nodes["nodes"],
             &(not Map.has_key?(&1, "ring_token") and not Map.has_key?(&1, "token"))
           )

    renewed = call(AgentTalk.TestPM, "register_node", Map.take(pm, ["role", "node_id", "token"]))

    same_credentials =
      renewed["token"] == pm["token"] and renewed["ring_token"] == pm["ring_token"]

    assert same_credentials, "renewal must return complete, unchanged credentials"
    assert renewed["node_id"] == pm["node_id"]
    assert renewed["expires_in_seconds"] == 86_400

    sent =
      call(
        AgentTalk.TestPM,
        "communicate",
        auth(renewed, %{action: "send", to_role: "worker", message: "Build it"})
      )

    assert sent["delivered_to"] == ids

    for {name, node} <- workers do
      inbox_status = call(name, "list_nodes", auth(node, %{role: "absent"}))
      assert inbox_status["nodes"] == []

      assert inbox_status["inbox"] == %{
               "pending_messages" => 1,
               "next_message_id" => sent["message_id"]
             }

      received = call(name, "communicate", auth(node, %{action: "receive"}))
      assert Enum.map(received["messages"], & &1["from"]) == [pm["node_id"]]
      assert Enum.map(received["messages"], & &1["ring_id"]) == [pm["ring_id"]]

      call(
        name,
        "communicate",
        auth(node, %{action: "send", to: [pm["node_id"]], message: "Done"})
      )
    end

    inbox = call(AgentTalk.TestPM, "communicate", auth(pm, %{action: "receive"}))
    assert Enum.map(inbox["messages"], & &1["from"]) |> Enum.sort() == ids
    assert {:error, _} = Anubis.Client.call_tool(AgentTalk.TestPM, "register_node", %{})
    assert {:error, _} = Anubis.Client.call_tool(AgentTalk.TestPM, "list_nodes", %{})

    assert {:error, _} =
             Anubis.Client.call_tool(
               AgentTalk.TestPM,
               "communicate",
               auth(pm, %{action: "unknown"})
             )
  end

  test "ring scoping and invitation versus node credentials are enforced over MCP", %{url: url} do
    name = AgentTalk.TestScope
    client(name, url)
    pm = call(name, "register_node", %{role: "pm"})
    worker = call(name, "register_node", %{role: "reviewer", ring_token: pm["ring_token"]})
    other_pm = call(name, "register_node", %{role: "pm"})

    outsider =
      call(name, "register_node", %{role: "reviewer", ring_token: other_pm["ring_token"]})

    found = call(name, "list_nodes", auth(pm, %{role: "reviewer"}))
    assert Enum.map(found["nodes"], & &1["node_id"]) == [worker["node_id"]]

    assert tool_error(name, "register_node", %{role: "worker", ring_token: "invalid"}) ==
             "invalid ring token"

    assert tool_error(name, "list_nodes", %{node_id: worker["node_id"], token: pm["ring_token"]}) ==
             "invalid node token"

    assert tool_error(name, "register_node", %{role: "worker", node_id: "chosen"}) =~
             "renewal requires both"

    assert tool_error(
             name,
             "communicate",
             auth(pm, %{
               action: "send",
               to: [worker["node_id"], outsider["node_id"]],
               message: "Mixed"
             })
           ) =~ "unknown or expired recipients"

    assert call(name, "communicate", auth(worker, %{action: "receive"}))["messages"] == []

    sent =
      call(name, "communicate", auth(pm, %{action: "send", to_role: "all", message: "Ring only"}))

    assert sent["delivered_to"] == [worker["node_id"]]
    assert call(name, "communicate", auth(outsider, %{action: "receive"}))["messages"] == []
  end

  test "raw MCP initialization provides ring onboarding and exactly three tools", %{url: url} do
    response =
      post(url, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "raw-test", version: "1"}
        }
      })

    assert response.status == 200
    result = decode(response.body)["result"]
    assert result["protocolVersion"] == "2025-11-25"
    assert result["serverInfo"]["version"] == to_string(Application.spec(:agent_talk, :vsn))
    assert result["instructions"] =~ "ring_token"
    session = List.keyfind(response.headers, "mcp-session-id", 0) |> elem(1)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", "2025-11-25"}]

    assert post(url, %{jsonrpc: "2.0", method: "notifications/initialized"}, headers).status ==
             202

    response = post(url, %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}}, headers)
    assert response.status == 200
    assert length(decode(response.body)["result"]["tools"]) == 3
  end

  test "rejects foreign browser origins", %{url: url} do
    assert post(url, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, [
             {"origin", "https://example.com"}
           ]).status == 403
  end

  defp client(name, url) do
    start_supervised!(
      {Anubis.Client,
       name: name,
       transport: {:streamable_http, base_url: url},
       client_info: %{"name" => to_string(name), "version" => "1"},
       capabilities: %{}}
    )

    assert :ok = Anubis.Client.await_ready(name)
  end

  defp call(client, tool, args) do
    assert {:ok, response} = Anubis.Client.call_tool(client, tool, args)
    refute response.is_error, "MCP tool failed (response omitted to protect credentials)"
    response.result["structuredContent"]
  end

  defp tool_error(client, tool, args) do
    assert {:ok, response} = Anubis.Client.call_tool(client, tool, args)
    assert response.is_error, "expected a tool error (response omitted to protect credentials)"
    Enum.map_join(response.result["content"], "\n", & &1["text"])
  end

  defp auth(node, fields),
    do: Map.merge(%{node_id: node["node_id"], token: node["token"]}, fields)

  defp post(url, body, headers \\ []) do
    request =
      Finch.build(
        :post,
        url <> "/mcp",
        [
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"} | headers
        ],
        Jason.encode!(body)
      )

    {:ok, response} = Finch.request(request, Anubis.Finch)
    response
  end

  defp decode("{" <> _ = body), do: Jason.decode!(body)

  defp decode(body),
    do:
      body
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "data: "))
      |> String.replace_prefix("data: ", "")
      |> Jason.decode!()
end
