defmodule Echo.Skills.Variables do
  @moduledoc """
  Resolves a skill run's variables, and answers
  `Echo.Agents.VariableResolver` for conversations a run started.

  Scopes are `"skill_run:<id>"`. A scope names the **run**, not the skill, for
  two reasons and either would be sufficient:

    * `kind: input` variables live in `skill_runs.input` and are per-run, so a
      skill id could not resolve them at all.
    * The run row is inserted before the conversation is started, so its id can
      be handed to `Echo.Agents.ConversationManager.start_conversation/1` as an
      opt. The session id cannot go the other way in time: `start_conversation/1`
      generates it itself and `ConversationServer.init/1` runs synchronously
      inside that call, so `skill_runs.session_id` is not written until after
      the first turn's config has already been read.

  This module is the only thing that knows the format of a scope. `Echo.Agents`
  stores the string and hands it back.
  """

  @behaviour Echo.Agents.VariableResolver

  import Ecto.Query, warn: false

  alias Echo.Repo
  alias Echo.Skills.Run
  alias Echo.Skills.Skill
  alias Echo.Skills.Variable

  @doc """
  The scope string for a run, stored on its conversation.
  """
  def scope(%Run{id: id}), do: "skill_run:#{id}"

  @doc """
  Checks that every required variable can be filled before the first model call.

  A skill missing a value should fail immediately with a clear message, not burn
  a turn and then fail inside a tool. `input` variables are checked against this
  run's payload; `config` against the bound literal.
  """
  def check_required(%Skill{} = skill, input) when is_map(input) do
    variables = skill.variables || []

    case for(v <- variables, v.required and not filled?(v, input), do: v.name) do
      [] -> :ok
      missing -> {:error, {:unbound_variables, missing}}
    end
  end

  defp filled?(%Variable{kind: "config", value: value}, _input), do: not is_nil(value)
  defp filled?(%Variable{kind: "input", name: name}, input), do: Map.has_key?(input, name)
  defp filled?(_variable, _input), do: false

  @impl true
  def fetch("skill_run:" <> run_id, names) do
    with {id, ""} <- Integer.parse(run_id),
         %Run{} = run <- Repo.get(Run, id) do
      declared =
        Repo.all(from v in Variable, where: v.skill_id == ^run.skill_id and v.name in ^names)

      {:ok, Map.new(Enum.flat_map(declared, &binding(&1, run)))}
    else
      _ -> {:error, {:unknown_scope, run_id}}
    end
  end

  def fetch(scope, _names), do: {:error, {:unknown_scope, scope}}

  # An unbound variable yields nothing rather than an empty string. From where
  # the model sits, "declared but never bound" and "never declared" are the same
  # fact, and collapsing them means one error path instead of two.
  #
  # Phase 1 marks everything `:plain`, so nothing is scrubbed out of a tool
  # result. Phase 6 adds a `secret` clause returning `:sensitive`, and nothing
  # in `Echo.Agents` changes.
  defp binding(%Variable{kind: "config", name: name, type: type, value: value}, _run)
       when is_binary(value),
       do: [{name, {cast(value, type), :plain}}]

  defp binding(%Variable{kind: "input", name: name}, %Run{input: input}) do
    case Map.fetch(input || %{}, name) do
      # `input` arrives as decoded JSON and is already typed; only the `value`
      # column, which is text whatever the declared type, needs casting.
      {:ok, value} -> [{name, {value, :plain}}]
      :error -> []
    end
  end

  defp binding(_variable, _run), do: []

  defp cast(value, "number") do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  defp cast("true", "boolean"), do: true
  defp cast("false", "boolean"), do: false
  defp cast(value, _type), do: value
end
