defmodule AgentTalk do
  @moduledoc "A small MCP message hub for a PM and its invited agents."

  alias Anubis.Server.Response

  @doc false
  def tool_reply({:ok, data}, frame) do
    response = Response.tool() |> Response.json(data) |> Response.structured(data)
    {:reply, response, frame}
  end

  # The code is the stable contract clients branch on (structuredContent.error.code);
  # the text is advisory. Set structured_content directly so the error text is not
  # duplicated as a second JSON content block.
  def tool_reply({:error, code, message}, frame) do
    response = %{
      Response.error(Response.tool(), message)
      | structured_content: %{error: %{code: code, message: message}}
    }

    {:reply, response, frame}
  end
end
