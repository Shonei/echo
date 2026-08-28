defmodule Echo.Skills.Variables do
  @moduledoc """
  Resolves a skill's variables, and answers `Echo.Agents.VariableResolver` for
  the conversations its runs start.

  Scopes are `"skill:<id>"`. A run's own text does not come through here: it is
  substituted into the system prompt instead, so `$.name` in a tool argument is
  a skill variable and `$.name` in the instructions is the run's input.

  The only reader of `skill_variables.value`, which is where encryption goes.
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

  # A variable with no value yields nothing, so the model is told it is unknown
  # rather than handed an empty string.
  defp resolved(%Variable{name: name, kind: kind, type: type, value: value})
       when is_binary(value),
       do: [{name, {cast(value, type), sensitivity(kind)}}]

  defp resolved(_variable), do: []

  # Only secrets are scrubbed from a tool result. Replacing a config value like
  # "1" would corrupt every result that happened to contain it.
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
