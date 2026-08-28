defmodule EchoWeb.SkillVariableJSON do
  alias Echo.Skills.Variable

  @doc """
  Renders a skill's declared variables, in display order.
  """
  def index(%{variables: variables}) do
    %{data: for(variable <- variables, do: data(variable))}
  end

  @doc """
  Renders a single variable.
  """
  def show(%{variable: variable}) do
    %{data: data(variable)}
  end

  @doc """
  Renders the result of replacing a declaration set, including what the
  replacement cost: bindings that were dropped, and required variables that are
  now unbound and would stop a run.
  """
  def defined(%{result: result}) do
    %{
      data: for(variable <- result.variables, do: data(variable)),
      dropped_bindings: result.dropped_bindings,
      unbound: result.unbound
    }
  end

  defp data(%Variable{} = variable) do
    %{
      id: variable.id,
      skill_id: variable.skill_id,
      name: variable.name,
      kind: variable.kind,
      type: variable.type,
      description: variable.description,
      required: variable.required,
      position: variable.position,
      # In Phase 6 this becomes conditional on kind: a secret's value is never
      # rendered, only whether it is bound.
      value: variable.value,
      created_at: variable.inserted_at,
      updated_at: variable.updated_at
    }
  end
end
