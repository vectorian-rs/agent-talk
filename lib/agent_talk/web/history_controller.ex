defmodule AgentTalk.Web.HistoryController do
  use Phoenix.Controller, formats: [:html]
  alias AgentTalk.History

  def export(conn, params) do
    with {:ok, day} <- date(Map.get(params, "date")),
         {:ok, ring} <- ring(Map.get(params, "ring")) do
      case History.daily(Application.get_env(:agent_talk, :history_file), day, ring) do
        {:ok, events} ->
          filename = "agent-talk-#{Date.to_iso8601(day)}-#{ring || "all-rings"}.md"

          conn
          |> put_resp_content_type("text/markdown", "utf-8")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(200, History.markdown(day, events))

        {:error, _} ->
          send_resp(conn, 503, "Conversation archive unavailable.")
      end
    else
      _ -> send_resp(conn, 400, "Use date=YYYY-MM-DD (UTC) and an optional ring ID.")
    end
  end

  defp date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date(_), do: {:error, :invalid_date}
  defp ring(value) when value in [nil, ""], do: {:ok, nil}

  defp ring(value) when is_binary(value) do
    if byte_size(value) <= 64 and Regex.match?(~r/\Aring-[1-9][0-9]*\z/, value),
      do: {:ok, value},
      else: {:error, :invalid_ring}
  end

  defp ring(_), do: {:error, :invalid_ring}
end
