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
    assert has_element?(view, "#ring-empty")
    pm = register(%{role: "pm", project: "hiko", name: "hiko / pm"})
    first = join(pm, "hiko / w-1")
    second = join(pm, "hiko / w-2")
    assert has_element?(view, "#agent-count", "3")
    assert has_element?(view, "#agent-#{first.node_id} .agent-name", "hiko / w-1")
    assert has_element?(view, "#agent-#{first.node_id} .agent-role", "Worker · #{first.node_id}")
    assert has_element?(view, "#ring-select .ring-chip[phx-value-ring='#{pm.ring_id}']", "hiko")

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
    assert has_element?(view, "#message-#{id} .party-name", "hiko / pm")
    assert has_element?(view, "#message-#{id} .recipient-name", "hiko / w-1")
    assert has_element?(view, "#message-#{id} .message-kind", pm.ring_id)
    assert has_element?(view, "#message-#{id} .delivery-status", "Queued")
    assert has_element?(view, "#agent-#{first.node_id} .agent-pending", "1 in inbox")

    credential_leak =
      Enum.any?([pm.token, first.token, pm.ring_token], &String.contains?(render(view), &1))

    refute credential_leak, "the human UI must not expose node or ring tokens"
    assert {:ok, %{messages: [%{id: ^id}]}} = Hub.communicate(auth(first, %{action: "receive"}))
    assert has_element?(view, "#message-#{id} .delivery-status", "Collected 1/2")

    assert {:ok, %{message_id: reply}} =
             Hub.communicate(
               auth(first, %{
                 action: "send",
                 to: [pm.node_id],
                 message: "View built",
                 reply_to: id
               })
             )

    assert has_element?(view, "#message-#{reply} .reply-ref", "↩ #{id}")
    refute has_element?(view, "#message-#{id} .reply-ref")
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

  test "ring selection scopes agents and messages and stays selected on live updates" do
    pm = register(%{role: "pm", project: "hiko", name: "hiko / pm"})
    worker = join(pm, "hiko / w-1")
    other_pm = register(%{role: "pm", project: "celeratax", name: "celeratax / pm"})
    other_worker = join(other_pm, "celeratax / w-1")

    send_message(
      pm,
      worker.node_id,
      "<script>window.agentInjected = true</script> https://example.com/review?a=1&b=2"
    )

    send_message(other_pm, other_worker.node_id, "Tax task")
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#ring-select .ring-chip[phx-value-ring='#{pm.ring_id}']", "hiko")

    assert has_element?(
             view,
             "#ring-select .ring-chip[phx-value-ring='#{other_pm.ring_id}']",
             "celeratax"
           )

    assert has_element?(view, "#agent-#{other_pm.node_id}", "celeratax / pm")
    refute has_element?(view, "#agent-#{pm.node_id}")
    assert has_element?(view, "#agent-count", "2")
    assert has_element?(view, "#message-stream", "Tax task")

    view |> element("#ring-select .ring-chip[phx-value-ring='#{pm.ring_id}']") |> render_click()
    assert has_element?(view, "#agent-#{pm.node_id}", "hiko / pm")
    refute has_element?(view, "#agent-#{other_pm.node_id}")
    refute has_element?(view, "#message-stream", "Tax task")
    assert render(view) =~ "&lt;script&gt;"
    refute has_element?(view, "#message-stream script")

    assert has_element?(
             view,
             "#message-stream a[href='https://example.com/review?a=1&b=2'][rel='noopener noreferrer']"
           )

    send_message(other_pm, other_worker.node_id, "Unselected ring update")
    assert has_element?(view, "#ring-select .ring-chip.is-selected[phx-value-ring='#{pm.ring_id}']")
    refute has_element?(view, "#message-stream", "Unselected ring update")
    assert has_element?(view, "#message-count", "1")

    view
    |> form("#message-filters", %{party: worker.node_id, query: "no-match"})
    |> render_change()

    assert has_element?(view, "#no-matches")
    view |> element("#ring-select .ring-chip[phx-value-ring='#{other_pm.ring_id}']") |> render_click()
    assert has_element?(view, "#message-stream", "Tax task")
    assert has_element?(view, "#message-stream", "Unselected ring update")
    assert has_element?(view, "#message-count", "2")
    refute has_element?(view, "#agent-#{pm.node_id}")
  end

  test "the operator sees an advertised purpose only for nodes that set one" do
    pm = register(%{role: "pm", project: "hiko", name: "hiko / pm"})

    deployer =
      register(%{
        role: "worker",
        ring_token: pm.ring_token,
        project: "hiko",
        name: "hiko / deploy",
        purpose: "runs deployments"
      })

    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#agent-#{deployer.node_id} .agent-purpose", "runs deployments")
    refute has_element?(view, "#agent-#{pm.node_id} .agent-purpose")
  end

  test "the operator evicts an agent, removing it from the live view" do
    pm = register(%{role: "pm", project: "hiko", name: "hiko / pm"})
    worker = join(pm, "hiko / w-1")
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#agent-#{worker.node_id}")

    view |> element("#agent-#{worker.node_id} .agent-evict") |> render_click()

    refute has_element?(view, "#agent-#{worker.node_id}")
    assert has_element?(view, "#agent-#{pm.node_id}"), "eviction is scoped to its target"
    {:ok, %{nodes: nodes}} = Hub.snapshot()
    refute Enum.any?(nodes, &(&1.node_id == worker.node_id))
  end

  test "the operator broadcasts a message to the selected ring from the dashboard" do
    pm = register(%{role: "pm", project: "hiko", name: "hiko / pm"})
    worker = join(pm, "hiko / w-1")
    {:ok, view, _} = live(build_conn(), "/")

    view
    |> form("#operator-broadcast", %{message: "Standup in five"})
    |> render_submit()

    assert has_element?(view, "#message-stream", "Standup in five")
    assert has_element?(view, "#message-stream .party-name", "Operator")
    assert {:ok, %{messages: [%{message: "Standup in five"}]}} =
             Hub.communicate(auth(worker, %{action: "receive"}))
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

  defp join(pm, name \\ nil),
    do: register(%{role: "worker", ring_token: pm.ring_token, project: pm.project, name: name})

  defp auth(node, fields), do: Map.merge(%{node_id: node.node_id, token: node.token}, fields)

  defp send_message(from, recipient, message),
    do: Hub.communicate(auth(from, %{action: "send", to: [recipient], message: message}))
end
