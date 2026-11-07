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

  test "live operator sees registrations, messages and collections without draining inboxes" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Agent messages"
    assert has_element?(view, "#empty-messages")
    assert has_element?(view, "#empty-agents")

    pm = register("operator-pm", "pm")
    backend = register("operator-backend")
    frontend = register("operator-frontend")
    assert has_element?(view, "#agent-count", "3")
    assert has_element?(view, "#agent-operator-backend")

    assert {:ok, %{message_id: id}} =
             Hub.communicate(
               auth(pm, %{
                 action: "send",
                 to_role: "implementation",
                 message: "Build the operator view"
               })
             )

    assert has_element?(view, "#message-#{id}", "Build the operator view")
    assert has_element?(view, "#message-#{id} .delivery-status", "Queued")
    assert has_element?(view, "#agent-operator-backend .agent-pending", "1 in inbox")
    refute render(view) =~ pm.token
    refute render(view) =~ backend.token

    assert {:ok, %{messages: [%{id: ^id}]}} = Hub.communicate(auth(backend, %{action: "receive"}))
    assert has_element?(view, "#message-#{id} .delivery-status", "Collected 1/2")

    assert {:ok, %{messages: [%{id: ^id}]}} =
             Hub.communicate(auth(frontend, %{action: "receive"}))

    assert has_element?(view, "#message-#{id} .delivery-status", "Collected")
    assert has_element?(view, "#agent-operator-backend .agent-pending", "0 in inbox")
  end

  test "filters search both message text and parties and remain applied to live updates" do
    pm = register("filter-pm", "pm")
    backend = register("filter-backend")
    frontend = register("filter-frontend")
    {:ok, view, _html} = live(build_conn(), "/")

    send_message(pm, backend.node_id, "Backend API task")
    send_message(pm, frontend.node_id, "Frontend interface task")

    view |> form("#message-filters", %{party: "filter-backend", query: ""}) |> render_change()
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

  test "rendered messages escape agent supplied HTML" do
    pm = register("escape-pm", "pm")
    backend = register("escape-backend")
    send_message(pm, backend.node_id, "<script>window.agentInjected = true</script>")
    {:ok, view, _} = live(build_conn(), "/")
    assert render(view) =~ "&lt;script&gt;"
    refute has_element?(view, "#message-stream script")
  end

  defp reset_hub do
    :ok = Supervisor.terminate_child(AgentTalk.Supervisor, Hub)
    {:ok, _} = Supervisor.restart_child(AgentTalk.Supervisor, Hub)
    :ok
  end

  defp register(id, role \\ "implementation") do
    {:ok, node} = Hub.register(%{node_id: id, role: role})
    node
  end

  defp auth(node, args), do: Map.merge(%{node_id: node.node_id, token: node.token}, args)

  defp send_message(from, to, message) do
    {:ok, _} = Hub.communicate(auth(from, %{action: "send", to: [to], message: message}))
  end
end
