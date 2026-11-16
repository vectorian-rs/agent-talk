defmodule AgentTalk.SSETimeoutTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  test "socket read timeouts do not warn or stop SSE delivery" do
    log = stream_log([:read_timeout, {:sse_message, "after-timeout"}])
    refute log =~ "sse_unknown_message"
    assert_received {:stream_result, conn}
    assert conn.resp_body =~ "data: after-timeout"
  end

  test "other unknown SSE messages still warn" do
    assert stream_log([:unexpected_sse_message]) =~ "sse_unknown_message"
  end

  defp stream_log(messages) do
    capture_log(fn ->
      conn =
        Plug.Test.conn(:get, "/mcp")
        |> Anubis.SSE.Streaming.prepare_connection()

      Enum.each(messages, &send(self(), &1))
      send(self(), :close_sse)
      result = Anubis.SSE.Streaming.start(conn, self(), "timeout-regression")
      send(self(), {:stream_result, result})
    end)
  end
end
