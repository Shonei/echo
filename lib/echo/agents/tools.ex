defmodule Echo.Agents.Tools do
  @moduledoc """
  Registry of tools Echo executes itself, and the execution path for them.

  The model emits a `functionCall`, `Echo.Agents.ConversationServer` runs it
  through `run_all/4`, and the `functionResponse` goes back without the client
  being involved. Tools a client declares for itself are not listed here, so
  they pass through untouched.
  """

  alias Echo.Agents.Tool
  alias Echo.Agents.Tools.CreateSkill
  alias Echo.Agents.Tools.DefineSkillVariables
  alias Echo.Agents.Tools.GetSkill
  alias Echo.Agents.Tools.GetSkillRun
  alias Echo.Agents.Tools.HttpRequest
  alias Echo.Agents.Tools.ListSkills
  alias Echo.Agents.Tools.RunSkill
  alias Echo.Agents.Tools.UpdateSkill
  alias Echo.Agents.Tools.UpdateSkillInstructions
  alias Echo.Agents.Variables

  require Logger

  @backends %{
    "http_request" => HttpRequest,
    "create_skill" => CreateSkill,
    "update_skill" => UpdateSkill,
    "update_skill_instructions" => UpdateSkillInstructions,
    "define_skill_variables" => DefineSkillVariables,
    "list_skills" => ListSkills,
    "get_skill" => GetSkill,
    "run_skill" => RunSkill,
    "get_skill_run" => GetSkillRun
  }

  # Tools for managing skills. They belong to an agent an operator is talking to,
  # never to a skill: one that could write skills is a careless approval away
  # from rewriting its own grants, and one that could read them has no business
  # doing so.
  @skill_management ~w(create_skill update_skill update_skill_instructions
                       define_skill_variables list_skills get_skill
                       run_skill get_skill_run)

  @doc """
  Names of every server-executed tool.
  """
  def names, do: @backends |> Map.keys() |> Enum.sort()

  @doc """
  Names a skill may be granted.
  """
  def skill_grantable_names, do: Enum.sort(names() -- @skill_management)

  @doc """
  Names of the tools that manage skills. An operator's own conversation may have
  these; a skill may not.
  """
  def skill_management_names, do: Enum.sort(@skill_management)

  @doc """
  The module backing a name, or `nil`.
  """
  def backend(name), do: Map.get(@backends, name)

  # --- Declarations ---

  @doc """
  Builds the `tools` entry for the given tool names, ready to merge into the
  conversation opts. Returns `nil` when none of the names are known.

  Declarations are canonical JSON Schema; the provider wraps them in its own
  syntax, so the same tool works on any backend.
  """
  def declarations(names, provider \\ Echo.Agents.Providers.Gemini) when is_list(names) do
    declarations =
      names
      |> Enum.filter(&Map.has_key?(@backends, &1))
      |> Enum.map(&Map.fetch!(@backends, &1).declaration())

    case declarations do
      [] -> nil
      list -> provider.build_function_tools(list)
    end
  end

  # --- Building a conversation's toolset ---

  @doc """
  Resolves a conversation's durable tool settings into `Echo.Agents.Tool`
  structs.

  `tool_config` is the authoritative statement of what Echo may execute and
  how: `%{"http_request" => %{"gate" => "mutations", "config" => %{...}}}`.

  When it is absent or empty, the toolset is derived from the declarations
  instead — every server-executed tool the conversation declared, ungated. That
  fallback is what keeps every conversation predating this column, and every
  caller that only sends `tools`, behaving identically.

  A name with nothing to back it is dropped rather than kept as a broken entry.
  Keeping it would be worse than useless: an unresolvable tool looks exactly
  like a client-side one at execution time, so the call would fall through to
  the caller and be indistinguishable from one waiting on a human.
  """
  def build(tool_config, _declared)
      when is_map(tool_config) and map_size(tool_config) > 0 do
    tool_config
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(&resolve_tool/1)
  end

  def build(_tool_config, declared), do: derive(declared)

  defp derive(declared) do
    for name <- enabled(declared), do: %Tool{name: name, executor: {:module, @backends[name]}}
  end

  defp resolve_tool({name, settings}) when is_map(settings) do
    case executor(name, settings) do
      nil ->
        Logger.warning("Tool has no backend and was dropped from the toolset", tool: name)
        []

      executor ->
        [
          %Tool{
            name: name,
            executor: executor,
            gate: gate(settings["gate"]),
            config: settings["config"] || %{}
          }
        ]
    end
  end

  defp resolve_tool({name, _settings}), do: resolve_tool({name, %{}})

  defp executor(name, _settings) do
    case Map.get(@backends, name) do
      nil -> nil
      module -> {:module, module}
    end
  end

  # Fails closed. Gates are validated on write, so anything else is a bad row.
  defp gate(nil), do: :never
  defp gate("never"), do: :never
  defp gate("mutations"), do: :mutations
  defp gate("always"), do: :always

  defp gate(other) do
    Logger.warning("Unrecognised tool gate, treating it as :always", gate: inspect(other))
    :always
  end

  @doc """
  Names of server-executed tools among a conversation's declarations.

  Used to derive a toolset when there is no explicit `tool_config`, and to
  validate that a name is one Echo owns.
  """
  def enabled(tools) when is_list(tools) do
    tools
    |> Enum.flat_map(fn
      # Gemini nests declarations; OpenRouter lists them flat. OpenRouter's own
      # server tools carry no `"function"` key, so they never match -- it
      # resolves those itself.
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

  # --- Deciding what runs ---

  @doc """
  Splits a turn's calls into the ones to run now and the ones that stop for a
  human.

  A call for a tool not in the toolset is in neither list: it is a client-side
  tool, and falls through to the caller untouched.

  **If any call in the turn is gated, none of them run.** Answering some of a
  turn's calls and not others is a shape Gemini tolerates and OpenRouter rejects
  outright, and it would fire a real side effect while waiting on a decision
  about its neighbour.
  """
  def partition_calls(parts, toolset) when is_list(parts) and is_list(toolset) do
    calls =
      Enum.flat_map(parts, fn
        %{"functionCall" => %{"name" => name} = call} ->
          case find(toolset, name) do
            nil -> []
            tool -> [{tool, call}]
          end

        _ ->
          []
      end)

    case Enum.split_with(calls, fn {tool, call} -> gated?(tool, call) end) do
      {[], runnable} -> {Enum.map(runnable, &elem(&1, 1)), []}
      {gated, runnable} -> {[], Enum.map(gated ++ runnable, &elem(&1, 1))}
    end
  end

  def partition_calls(_parts, _toolset), do: {[], []}

  @doc """
  The calls this toolset can execute right now. Kept for callers that do not
  care about the parked half.
  """
  def executable_calls(parts, toolset) do
    {runnable, _parked} = partition_calls(parts, toolset)
    runnable
  end

  @doc """
  The tool with this name, or `nil`.
  """
  def find(toolset, name), do: Enum.find(toolset, &(&1.name == name))

  defp gated?(%Tool{gate: :never}, _call), do: false
  defp gated?(%Tool{gate: :always}, _call), do: true

  defp gated?(%Tool{gate: :mutations, executor: {:module, module}}, call),
    do: module.mutating?(Map.get(call, "args") || %{})

  # A row-backed block cannot classify its own calls, so `:mutations` means stop.
  defp gated?(%Tool{gate: :mutations}, _call), do: true

  # --- Running ---

  @doc """
  Wraps a result as this call's `functionResponse` part.

  A call's `"id"`, when it has one, is carried onto the response: OpenRouter
  pairs a result with its call by id rather than by name, and drops the turn if
  it can't find the match.

  Public because a caller sometimes has to answer a call it never ran — one
  naming a variable that does not exist, say. That comes back in the same shape
  as a tool's own failure, so the model sees one kind of failure rather than
  two.
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
  Runs a whole round of calls and returns the `functionResponse` parts, ready to
  persist.

  Both halves of variable substitution live here rather than in the tools:

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
  be answered — a deleted skill, a store that is down. That is not something the
  model can fix by rewriting its call.
  """
  def run_all(calls, toolset, scope, resolver) when is_list(calls) do
    case prepare(calls, scope, resolver) do
      {:ok, prepared, used} ->
        used = Variables.merge(used)
        {:ok, Enum.map(prepared, &(&1 |> answer(toolset) |> Variables.scrub(used)))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare(calls, scope, resolver) do
    Enum.reduce_while(calls, {:ok, [], []}, fn call, {:ok, prepared, used} ->
      case Variables.resolve(Map.get(call, "args") || %{}, scope, resolver) do
        {:ok, args, call_used} ->
          {:cont, {:ok, prepared ++ [{:run, Map.put(call, "args", args)}], used ++ call_used}}

        # Answered as a tool failure so the model can react, rather than
        # failing the turn.
        {:error, :unresolved, message} ->
          {:cont, {:ok, prepared ++ [{:refuse, call, message}], used}}

        {:error, :unavailable, reason} ->
          {:halt, {:error, {:variables_unavailable, reason}}}
      end
    end)
  end

  defp answer({:run, %{"name" => name} = call}, toolset) do
    response(call, execute(find(toolset, name), Map.get(call, "args") || %{}))
  end

  defp answer({:refuse, call, message}, _toolset),
    do: response(call, %{"error" => message})

  defp execute(%Tool{executor: {:module, module}}, args), do: module.run(args)

  # Unreachable: `partition_calls/2` only returns calls found in the toolset.
  defp execute(other, _args) do
    Logger.error("No way to execute tool", tool: inspect(other))
    %{"error" => "This tool is not executable."}
  end
end
