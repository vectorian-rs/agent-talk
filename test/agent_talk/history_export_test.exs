defmodule AgentTalk.HistoryExportTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]
  alias AgentTalk.Hub
  @endpoint AgentTalk.Web.Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    original = Application.get_env(:agent_talk, :history_file)
    {:ok, original_child} = :supervisor.get_childspec(AgentTalk.Supervisor, Hub)
    file = Path.join(dir, "history.sqlite3")
    Application.put_env(:agent_talk, :history_file, file)
    :ok = Supervisor.terminate_child(AgentTalk.Supervisor, Hub)
    :ok = Supervisor.delete_child(AgentTalk.Supervisor, Hub)

    {:ok, _} =
      Supervisor.start_child(
        AgentTalk.Supervisor,
        {Hub,
         history_file: file,
         membership_file: Path.join(dir, "memberships.json"),
         history_limit: 2,
         pubsub: AgentTalk.PubSub}
      )

    on_exit(fn ->
      :ok = Supervisor.terminate_child(AgentTalk.Supervisor, Hub)
      :ok = Supervisor.delete_child(AgentTalk.Supervisor, Hub)
      {:ok, _} = Supervisor.start_child(AgentTalk.Supervisor, original_child)
      Application.put_env(:agent_talk, :history_file, original)
    end)

    %{history_file: file}
  end

  test "UI offers a daily ring export with all messages, public identities and collection times" do
    pm = register(%{role: "pm", project: "sample", name: "sample / pm"})
    worker = register(%{role: "worker", ring_token: pm.ring_token, name: "sample / worker"})
    other = register(%{role: "pm", project: "other"})
    other_worker = register(%{role: "worker", ring_token: other.ring_token})
    for n <- 1..4, do: send_message(pm, worker, "Review item #{n}")
    {:ok, _} = Hub.communicate(auth(worker, %{action: "receive"}))
    send_message(other, other_worker, "Other ring task")
    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#ring-selector", %{ring: pm.ring_id}) |> render_change()

    assert has_element?(
             view,
             "#history-export select[name='ring'] option[selected][value='#{pm.ring_id}']"
           )

    assert has_element?(view, "#history-export select[name='ring'] option[value='']", "All rings")
    assert has_element?(view, "#history-export input[type='date'][name='date']")
    assert has_element?(view, "#history-export button", "Download day")
    assert render(view) =~ "Archive: SQLite"

    conn =
      export(%{
        date: Date.to_iso8601(Date.utc_today()),
        ring: pm.ring_id
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment;"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    for n <- 1..4, do: assert(conn.resp_body =~ "Review item #{n}")
    refute conn.resp_body =~ "Other ring task"
    assert conn.resp_body =~ "sample / pm"
    assert conn.resp_body =~ "Collection:"

    refute Enum.any?(
             [pm.token, pm.ring_token, worker.token],
             &String.contains?(conn.resp_body, &1)
           ),
           "daily exports must not include registration credentials"

    all = export(%{date: Date.to_iso8601(Date.utc_today())})
    assert all.resp_body =~ "Other ring task"
  end

  test "invalid date/ring values return 400 and unavailable storage returns 503", %{
    history_file: file
  } do
    for params <- [
          %{},
          %{date: "2026-11-99"},
          %{date: %{bad: "value"}},
          %{date: "2026-11-10", ring: "' OR 1=1 --"},
          %{date: "2026-11-10", ring: ["ring-1"]}
        ] do
      assert export(params).status == 400
    end

    Application.put_env(:agent_talk, :history_file, file <> ".missing")
    assert export(%{date: "2026-11-10"}).status == 503

    refute File.exists?(file <> ".missing"),
           "a read-only export must not create a missing database"
  end

  test "history restored after restart keeps queued mail visible and collectable" do
    pm = register(%{role: "pm"})
    worker = register(%{role: "worker", ring_token: pm.ring_token})
    send_message(pm, worker, "Archived pending task")
    :ok = Supervisor.terminate_child(AgentTalk.Supervisor, Hub)
    {:ok, _} = Supervisor.restart_child(AgentTalk.Supervisor, Hub)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, ".message-item", "Archived pending task")
    assert has_element?(view, ".delivery-status", "Queued")

    assert {:ok, %{messages: [%{message: "Archived pending task"}]}} =
             Hub.communicate(auth(worker, %{action: "receive"}))
  end

  defp register(args) do
    {:ok, member} = Hub.register(args)
    member
  end

  defp export(params), do: get(build_conn(), "/history/export?" <> Plug.Conn.Query.encode(params))

  defp auth(node, fields), do: Map.merge(%{node_id: node.node_id, token: node.token}, fields)

  defp send_message(from, to, text),
    do: Hub.communicate(auth(from, %{action: "send", to: [to.node_id], message: text}))
end
