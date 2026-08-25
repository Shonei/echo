defmodule Echo.Agents.Tools do
  @moduledoc """
  Registry of tools Echo executes itself.

  Everything here runs server-side: the model emits a `functionCall`,
  `Echo.Agents.ConversationServer` runs it through `run/1`, and feeds the
  `functionResponse` straight back to the model without the client being
  involved. Tools declared by a client (the blog editor's `edit_text`, say) are
  not listed here, so they pass through untouched for the client to handle.
  """

  alias Echo.Agents.Tools.HttpRequest

  @backends %{"http_request" => HttpRequest}

  @doc """
  Names of every server-executed tool.
  """
  def names, do: Map.keys(@backends)

  @doc """
  Builds the `tools` entry for the given tool names, ready to merge into the
  conversation opts. Returns `nil` when none of the names are known.

  Declarations are written once in canonical JSON Schema; the provider wraps
  them in its own tool syntax, so the same tool works on any backend.
  """
  def tool_config(names, provider \\ Echo.Agents.Providers.Gemini) when is_list(names) do
    declarations =
      names
      |> Enum.filter(&Map.has_key?(@backends, &1))
      |> Enum.map(&Map.fetch!(@backends, &1).declaration())

    case declarations do
      [] -> nil
      list -> provider.build_function_tools(list)
    end
  end

  @doc """
  Names of server-executed tools a conversation actually declared.

  Execution is gated on this rather than on the tool name alone: a model can
  emit a call for a tool that was never offered to it, and in a conversation
  that only declared client-side tools we must not run it.
  """
  def enabled(tools) when is_list(tools) do
    tools
    |> Enum.flat_map(fn
      # Gemini nests declarations; OpenRouter lists them flat. OpenRouter's own
      # server-side tools (`openrouter:web_search`) carry no `"function"` key,
      # so they never match here — which is right: OpenRouter resolves them
      # itself and they must not enter Echo's tool loop.
      %{"functionDeclarations" => declarations} when is_list(declarations) ->
        Enum.map(declarations, &Map.get(&1, "name"))

      %{"type" => "function", "function" => %{"name" => name}} ->
        [name]

      _ ->
        []
    end)
    |> Enum.filter(&Map.has_key?(@backends, &1))
    |> Enum.uniq()
  end

  def enabled(_), do: []

  @doc """
  Picks out the `functionCall` parts this module can execute, limited to the
  tools the conversation enabled.
  """
  def executable_calls(parts, allowed) when is_list(parts) and is_list(allowed) do
    Enum.flat_map(parts, fn
      %{"functionCall" => %{"name" => name} = call} ->
        if name in allowed and Map.has_key?(@backends, name), do: [call], else: []

      _ ->
        []
    end)
  end

  def executable_calls(_, _), do: []

  @doc """
  Runs one call and wraps the result as a `functionResponse` part.

  A call's `"id"`, when it has one, is carried onto the response: OpenRouter
  pairs a result with its call by id rather than by name, and drops the turn
  if it can't find the match.
  """
  def run(%{"name" => name} = call) do
    args = Map.get(call, "args") || %{}
    result = Map.fetch!(@backends, name).run(args)

    response =
      case Map.get(call, "id") do
        nil -> %{"name" => name, "response" => result}
        id -> %{"name" => name, "response" => result, "id" => id}
      end

    %{"functionResponse" => response}
  end
end
