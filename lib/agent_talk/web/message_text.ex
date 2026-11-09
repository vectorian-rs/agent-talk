defmodule AgentTalk.Web.MessageText do
  @moduledoc "Splits message text into escaped text and explicit HTTP(S) links."
  @urls ~r{(https?://[^\s<>"']+)}iu

  def parts(text) do
    @urls
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.flat_map(fn part ->
      if Regex.match?(~r{\Ahttps?://}i, part) do
        url = trim_punctuation(part)

        case URI.new(url) do
          {:ok, %URI{host: host, userinfo: nil}} when is_binary(host) and host != "" ->
            suffix = binary_part(part, byte_size(url), byte_size(part) - byte_size(url))
            [%{text: url, url: url}, %{text: suffix, url: nil}]

          _ ->
            [%{text: part, url: nil}]
        end
      else
        [%{text: part, url: nil}]
      end
    end)
  end

  defp trim_punctuation(text) do
    last = String.last(text)

    unmatched_closing =
      Enum.any?([{")", "("}, {"]", "["}], fn {closing, opening} ->
        last == closing and
          length(String.split(text, closing)) > length(String.split(text, opening))
      end)

    if last in [".", ",", ";", "!", "?"] or unmatched_closing do
      text |> String.slice(0..-2//1) |> trim_punctuation()
    else
      text
    end
  end
end
