defmodule AgentTalk do
  @moduledoc "A small, shared MCP message hub for PM and implementation agents."

  alias Anubis.Server.Response

  @doc false
  def tool_reply({:ok, data}, frame) do
    response = Response.tool() |> Response.json(data) |> Response.structured(data)
    {:reply, response, frame}
  end

  def tool_reply({:error, reason}, frame) do
    {:reply, Response.error(Response.tool(), reason), frame}
  end
end
