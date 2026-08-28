defmodule Echo.Skills.Variables do
  @moduledoc """
  Resolves a skill's variables, and answers `Echo.Agents.VariableResolver` for
  conversations a run started.

  Scopes are `"skill:<id>"`. Variables belong to the skill, not to a run: one
  value, shared by every run of it. That is why the scope can name the skill
  directly, and why a resumed conversation resolves against whatever the skill
  holds now rather than against a snapshot.

  A run's own ad-hoc text does not come through here at all. It is substituted
  into the system prompt when the run starts (see `Echo.Skills.Runner`), so the
  two namespaces never meet: `$.name` in a *tool argument* is a skill variable,
  and `$.name` in the *instructions* is this run's input.

  This module is the only thing that knows the format of a scope, and the only
  thing that reads `skill_variables.value` — which is where encryption goes
  when it is added.
  """

  @behaviour Echo.Agents.VariableResolver

  import Ecto.Query, warn: false

  alias Echo.Repo
  alias Echo.Skills.Skill
  alias Echo.Skills.Variable

  @doc """
  The scope string for a skill, stored on the conversations its runs start.
  """
  def scope(%Skill{id: id}), do: "skill:#{id}"

  @doc """
  Checks that every required variable has a value before the first model call.

  A skill missing one should fail immediately with a clear message, not burn a
  turn and then fail inside a tool.
  """
  def check_required(%Skill{} = skill) do
    variables = skill.variables || []

    case for(v <- variables, v.required and is_nil(v.value), do: v.name) do
      [] -> :ok
      missing -> {:error, {:unbound_variables, missing}}
    end
  end

  @impl true
  def fetch("skill:" <> skill_id, names) do
    case Integer.parse(skill_id) do
      {id, ""} ->
        declared = Repo.all(from v in Variable, where: v.skill_id == ^id and v.name in ^names)
        {:ok, Map.new(Enum.flat_map(declared, &resolved/1))}

      _ ->
        {:error, {:unknown_scope, skill_id}}
    end
  end

  def fetch(scope, _names), do: {:error, {:unknown_scope, scope}}

  # An unbound variable yields nothing rather than an empty string. From where
  # the model sits, "declared but never given a value" and "never declared" are
  # the same fact, and collapsing them means one error path instead of two.
  defp resolved(%Variable{name: name, kind: kind, type: type, value: value})
       when is_binary(value),
       do: [{name, {cast(value, type), sensitivity(kind)}}]

  defp resolved(_variable), do: []

  # A secret's resolved value is replaced by its placeholder in whatever the
  # tool returned. Config is left alone: replacing it would corrupt results
  # rather than protect anything, since a value like "1" appears everywhere.
  defp sensitivity("secret"), do: :sensitive
  defp sensitivity(_kind), do: :plain

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
