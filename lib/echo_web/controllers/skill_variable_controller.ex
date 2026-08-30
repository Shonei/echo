defmodule EchoWeb.SkillVariableController do
  use EchoWeb, :controller

  alias Echo.Skills

  action_fallback EchoWeb.FallbackController

  def index(conn, %{"skill_id" => skill_id}) do
    skill = Skills.get_skill_by_id_or_slug!(skill_id)
    render(conn, :index, variables: Skills.list_variables(skill))
  end

  @doc """
  Replaces the whole declaration set. Declarative rather than patched, so it is
  idempotent when a caller retries.
  """
  def define(conn, %{"skill_id" => skill_id, "variables" => variables})
      when is_list(variables) do
    skill = Skills.get_skill_by_id_or_slug!(skill_id)

    with {:ok, result} <- Skills.define_variables(skill, variables) do
      render(conn, :defined, result: result)
    end
  end

  def define(_conn, %{"skill_id" => _id}), do: {:error, :missing_param, "variables"}

  @doc """
  Binds a `config` variable to a literal. Operator-only; no agent tool reaches
  this path.
  """
  def bind(conn, %{"skill_id" => skill_id, "name" => name, "variable" => attrs}) do
    skill = Skills.get_skill_by_id_or_slug!(skill_id)

    with {:ok, variable} <- Skills.bind_variable(skill, name, attrs) do
      render(conn, :show, variable: variable)
    end
  end

  def bind(_conn, %{"skill_id" => _id, "name" => _name}),
    do: {:error, :missing_param, "variable"}
end
