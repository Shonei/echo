defmodule Echo.SkillsFixtures do
  @moduledoc """
  Factories for skills tests. Each call inserts a committed row with a unique
  slug, safe against leftover data in the long-lived test database.
  """

  import Echo.DataCase, only: [unique: 1]

  alias Echo.Repo
  alias Echo.Skills

  def skill_fixture(attrs \\ %{}) do
    {:ok, skill} =
      attrs
      |> Enum.into(%{
        slug: unique("skill"),
        name: "Test skill",
        instructions: "Do the thing."
      })
      |> Skills.create_skill()

    skill
  end

  @doc """
  Declares one variable on a skill, keeping any it already has.

  `define_variables/2` replaces the whole set, so a fixture that called it
  directly would silently drop everything declared before it.
  """
  def variable_fixture(skill, attrs) do
    existing =
      skill
      |> Skills.list_variables()
      |> Enum.map(&Map.take(&1, [:name, :kind, :type, :description, :required]))

    attrs = Enum.into(attrs, %{kind: "config", type: "string", required: false})
    {:ok, _result} = Skills.define_variables(skill, existing ++ [attrs])

    variable = Repo.get_by!(Skills.Variable, skill_id: skill.id, name: to_string(attrs.name))

    case Map.get(attrs, :value) do
      nil -> variable
      value -> bind(skill, variable, value)
    end
  end

  defp bind(skill, variable, value) do
    {:ok, bound} = Skills.bind_variable(skill, variable.name, %{"value" => value})
    bound
  end

  def run_fixture(skill, attrs \\ %{}) do
    {:ok, run} =
      %Skills.Run{skill_id: skill.id}
      |> Skills.Run.create_changeset(Enum.into(attrs, %{"input" => %{}}))
      |> Repo.insert()

    run
  end
end
