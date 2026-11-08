defmodule AgentTalk.OperatorLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentTalk.Hub
  @endpoint AgentTalk.Web.Endpoint

  setup do
    reset_hub()
    on_exit(&reset_hub/0)
    :ok
  end

  test "operator sees ring membership, messages and collections without exposing either token" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Agent messages"
    assert has_element?(view, "#empty-messages")
    assert has_element?(view, "#empty-agents")
    pm = register(%{role: "pm"})
    first = join(pm)
    second = join(pm)
    assert has_element?(view, "#agent-count", "3")
    assert has_element?(view, "#agent-#{first.node_id} .agent-role", "Worker · #{pm.ring_id}")

    assert has_element?(
             view,
             "#agent-#{first.node_id} .agent-activity time[datetime='#{first.last_seen}']",
             "UTC"
           )

    assert {:ok, %{message_id: id}} =
             Hub.communicate(
               auth(pm, %{action: "send", to_role: "worker", message: "Build the operator view"})
             )

    assert has_element?(view, "#message-#{id}", "Build the operator view")
    assert has_element?(view, "#message-#{id} .message-kind", pm.ring_id)
    assert has_element?(view, "#message-#{id} .delivery-status", "Queued")
    assert has_element?(view, "#agent-#{first.node_id} .agent-pending", "1 in inbox")

    credential_leak =
      Enum.any?([pm.token, first.token, pm.ring_token], &String.contains?(render(view), &1))

    refute credential_leak, "the human UI must not expose node or ring tokens"
    assert {:ok, %{messages: [%{id: ^id}]}} = Hub.communicate(auth(first, %{action: "receive"}))
    assert has_element?(view, "#message-#{id} .delivery-status", "Collected 1/2")
    {:ok, %{nodes: nodes}} = Hub.snapshot()
    active = Enum.find(nodes, &(&1.node_id == first.node_id))

    assert has_element?(
             view,
             "#agent-#{first.node_id} .agent-activity time[datetime='#{active.last_seen}']"
           )

    assert {:ok, %{messages: [%{id: ^id}]}} = Hub.communicate(auth(second, %{action: "receive"}))
    assert has_element?(view, "#message-#{id} .delivery-status", "Collected")
    assert has_element?(view, "#agent-#{first.node_id} .agent-pending", "0 in inbox")
  end

  test "agent and message filters remain applied to live updates" do
    pm = register(%{role: "pm"})
    backend = join(pm)
    frontend = join(pm)
    {:ok, view, _} = live(build_conn(), "/")
    send_message(pm, backend.node_id, "Backend API task")
    send_message(pm, frontend.node_id, "Frontend interface task")
    view |> form("#message-filters", %{party: backend.node_id, query: ""}) |> render_change()
    assert render(view) =~ "Backend API task"
    refute render(view) =~ "Frontend interface task"
    view |> form("#message-filters", %{party: "all", query: "FRONTEND"}) |> render_change()
    assert render(view) =~ "Frontend interface task"
    refute render(view) =~ "Backend API task"
    send_message(pm, frontend.node_id, "Frontend tests task")
    assert render(view) =~ "Frontend tests task"
    view |> form("#message-filters", %{party: "all", query: "no-match"}) |> render_change()
    assert has_element?(view, "#no-matches")
  end

  test "operator sees multiple rings and escapes agent supplied HTML" do
    pm = register(%{role: "pm"})
    worker = join(pm)
    other_pm = register(%{role: "pm"})
    send_message(pm, worker.node_id, "<script>window.agentInjected = true</script>")
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#agent-#{pm.node_id}", pm.ring_id)
    assert has_element?(view, "#agent-#{other_pm.node_id}", other_pm.ring_id)
    assert render(view) =~ "&lt;script&gt;"
    refute has_element?(view, "#message-stream script")
  end

  defp reset_hub do
    :ok = Supervisor.terminate_child(AgentTalk.Supervisor, Hub)
    {:ok, _} = Supervisor.restart_child(AgentTalk.Supervisor, Hub)
    :ok
  end

  defp register(args) do
    {:ok, node} = Hub.register(args)
    node
  end

  defp join(pm), do: register(%{role: "worker", ring_token: pm.ring_token})
  defp auth(node, fields), do: Map.merge(%{node_id: node.node_id, token: node.token}, fields)

  defp send_message(from, recipient, message),
    do: Hub.communicate(auth(from, %{action: "send", to: [recipient], message: message}))
end
