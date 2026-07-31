defmodule EchoWeb.AgentChatHTML do
  use EchoWeb, :html

  embed_templates "agent_chat_html/*"

  @doc """
  Web sources the model grounded a reply in, pulled from the stored
  `groundingMetadata`. Returns `[%{uri: ..., title: ...}]`.
  """
  def grounding_sources(%{"groundingMetadata" => %{"groundingChunks" => chunks}})
      when is_list(chunks) do
    chunks
    |> Enum.flat_map(fn
      %{"web" => %{"uri" => uri} = web} when is_binary(uri) ->
        [%{uri: uri, title: Map.get(web, "title") || uri}]

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.uri)
  end

  def grounding_sources(_), do: []

  @doc """
  Search queries the model ran, from the stored `groundingMetadata`.
  """
  def search_queries(%{"groundingMetadata" => %{"webSearchQueries" => queries}})
      when is_list(queries),
      do: queries

  def search_queries(_), do: []

  @doc """
  URLs the model fetched, from the stored `urlContextMetadata`. Returns
  `[%{uri: ..., status: ...}]`.
  """
  def fetched_urls(%{"urlContextMetadata" => %{"urlMetadata" => urls}}) when is_list(urls) do
    Enum.flat_map(urls, fn
      %{"retrievedUrl" => uri} = entry when is_binary(uri) ->
        [%{uri: uri, status: pretty_status(Map.get(entry, "urlRetrievalStatus"))}]

      _ ->
        []
    end)
  end

  def fetched_urls(_), do: []

  @doc """
  True when a message carries anything worth rendering under the reply.
  """
  def has_tool_activity?(metadata) when is_map(metadata) do
    grounding_sources(metadata) != [] or search_queries(metadata) != [] or
      fetched_urls(metadata) != []
  end

  def has_tool_activity?(_), do: false

  defp pretty_status("URL_RETRIEVAL_STATUS_SUCCESS"), do: "ok"
  defp pretty_status("URL_RETRIEVAL_STATUS_ERROR"), do: "failed"
  defp pretty_status("URL_RETRIEVAL_STATUS_PAYWALL"), do: "paywalled"
  defp pretty_status("URL_RETRIEVAL_STATUS_UNSAFE"), do: "unsafe"
  defp pretty_status(nil), do: nil

  defp pretty_status(other) when is_binary(other) do
    other |> String.replace_prefix("URL_RETRIEVAL_STATUS_", "") |> String.downcase()
  end
end
