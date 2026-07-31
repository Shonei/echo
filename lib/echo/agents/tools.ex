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
  """
  def tool_config(names) when is_list(names) do
    declarations =
      names
      |> Enum.filter(&Map.has_key?(@backends, &1))
      |> Enum.map(&Map.fetch!(@backends, &1).declaration())

    case declarations do
      [] -> nil
      list -> %{"functionDeclarations" => list}
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
      %{"functionDeclarations" => declarations} when is_list(declarations) ->
        Enum.map(declarations, &Map.get(&1, "name"))

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
  """
  def run(%{"name" => name} = call) do
    args = Map.get(call, "args") || %{}
    result = Map.fetch!(@backends, name).run(args)

    %{
      "functionResponse" => %{
        "name" => name,
        "response" => result
      }
    }
  end
end
