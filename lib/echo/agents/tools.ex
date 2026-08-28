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
  alias Echo.Agents.Variables

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
  Wraps a result as this call's `functionResponse` part.

  A call's `"id"`, when it has one, is carried onto the response: OpenRouter
  pairs a result with its call by id rather than by name, and drops the turn
  if it can't find the match.

  Public because a caller sometimes has to answer a call it never ran — one
  naming a variable that does not exist, say. That comes back in the same shape
  as a tool's own failure, so the model sees one kind of failure rather than
  two, and it deliberately never touches `@backends`.
  """
  def response(%{"name" => name} = call, result) do
    body =
      case Map.get(call, "id") do
        nil -> %{"name" => name, "response" => result}
        id -> %{"name" => name, "response" => result, "id" => id}
      end

    %{"functionResponse" => body}
  end

  @doc """
  Runs one call and wraps the result as a `functionResponse` part.

  Takes arguments as given. Prefer `run_all/2`, which resolves `$.name`
  placeholders first and scrubs the result after.
  """
  def run(%{"name" => name} = call) do
    args = Map.get(call, "args") || %{}
    # Still `fetch!`: `executable_calls/2` upholds the invariant that a name
    # reaching here is one we own, so a violation is a bug in this module rather
    # than something to hand the model.
    response(call, Map.fetch!(@backends, name).run(args))
  end

  @doc """
  Runs a whole round of calls under one variable scope and returns the
  `functionResponse` parts, ready to persist.

  This, not `run/1`, is what a caller should reach for, because both halves of
  variable substitution live here rather than in the tools:

    * `$.name` in an argument becomes the real value, on this stack and nowhere
      else — the arguments already in `ai_messages` keep the placeholder;
    * every resolved sensitive value is replaced by its placeholder in what
      comes back, before any of it is persisted or shown to the model.

  Arguments for **every** call are resolved before **any** of them runs. Doing
  it per call would mean a scope that fails on the second one had already fired
  the first one's side effect, which for `http_request` is a real request to a
  real service.

  Results are scrubbed against the whole round's values rather than each call's
  own. It costs nothing and closes the case where one call's result reflects a
  value a sibling sent.

  Order is preserved: Gemini puts no id on a `functionResponse` and pairs
  parallel calls by position.

  Returns `{:ok, parts}`, or `{:error, reason}` when the scope itself could not
  be answered — a deleted run, a store that is down. That is not something the
  model can fix by rewriting its call.
  """
  def run_all(calls, scope \\ nil) when is_list(calls) do
    case prepare(calls, scope) do
      {:ok, prepared, used} ->
        used = Variables.merge(used)
        {:ok, Enum.map(prepared, &(&1 |> answer() |> Variables.scrub(used)))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare(calls, scope) do
    Enum.reduce_while(calls, {:ok, [], []}, fn call, {:ok, prepared, used} ->
      case Variables.resolve(Map.get(call, "args") || %{}, scope) do
        {:ok, args, call_used} ->
          {:cont, {:ok, prepared ++ [{:run, Map.put(call, "args", args)}], used ++ call_used}}

        # The model named a variable that does not exist. It wrote the call, so
        # it is the one told, and the turn carries on -- the same style as every
        # other tool failure.
        {:error, :unresolved, message} ->
          {:cont, {:ok, prepared ++ [{:refuse, call, message}], used}}

        {:error, :unavailable, reason} ->
          {:halt, {:error, {:variables_unavailable, reason}}}
      end
    end)
  end

  defp answer({:run, call}), do: run(call)
  defp answer({:refuse, call, message}), do: response(call, %{"error" => message})
end
