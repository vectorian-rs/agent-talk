defmodule AgentTalk.MessageTextTest do
  use ExUnit.Case, async: true
  alias AgentTalk.Web.MessageText

  test "links explicit URLs while preserving every character and line break" do
    text =
      "pick up #482 lens:contract\nRead (https://github.com/org/repo/issues/482), then https://example.com/a_(b).\nNo source edits."

    parts = MessageText.parts(text)
    assert Enum.map_join(parts, & &1.text) == text

    assert Enum.flat_map(parts, &if(&1.url, do: [&1.url], else: [])) == [
             "https://github.com/org/repo/issues/482",
             "https://example.com/a_(b)"
           ]
  end

  test "HTML, unsupported schemes, embedded credentials and bare references remain text" do
    text =
      "<script>alert(1)</script> javascript:alert(2) https://user:private@example.com #482 9cd32e9c"

    parts = MessageText.parts(text)
    assert Enum.all?(parts, &is_nil(&1.url))
    assert Enum.map_join(parts, & &1.text) == text
  end
end
