defmodule Echo.Agents.Tools.DefineSkillVariables do
  @behaviour Echo.Agents.ToolBackend

  alias Echo.Agents.Tools.SkillAuthoring

  @impl true
  def declaration do
    %{
      "name" => "define_skill_variables",
      "description" =>
        "Declares what values a skill needs, replacing the whole set. " <>
          "You say what a skill needs; an operator says what fills it, so no value is set " <>
          "here and you are never shown one. Reference a variable as $.name in a tool " <>
          "argument. A variable whose name is unchanged keeps the value it already had.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "slug" => %{"type" => "string", "description" => "Which skill to declare on."},
          "variables" => %{
            "type" => "array",
            "description" => "The complete set. Anything left out is removed.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{
                  "type" => "string",
                  "description" => "Lowercase letters, digits and underscores, e.g. repo_name."
                },
                "kind" => %{
                  "type" => "string",
                  "description" =>
                    "config for ordinary settings, secret for credentials. A secret is " <>
                      "scrubbed out of tool results and never shown to you.",
                  "enum" => ["config", "secret"]
                },
                "type" => %{"type" => "string", "enum" => ["string", "number", "boolean"]},
                "description" => %{
                  "type" => "string",
                  "description" => "What it is for. Shown to whoever fills it in."
                },
                "required" => %{
                  "type" => "boolean",
                  "description" => "A run refuses to start while a required one has no value."
                }
              },
              "required" => ["name", "kind"]
            }
          }
        },
        "required" => ["slug", "variables"]
      }
    }
  end

  @impl true
  def run(%{"slug" => slug, "variables" => variables}) when is_list(variables) do
    with {:ok, skill} <- SkillAuthoring.fetch(slug),
         {:ok, result} <- Echo.Skills.define_variables(skill, variables) do
      %{
        "variables" =>
          Enum.map(result.variables, fn variable ->
            %{
              "name" => variable.name,
              "kind" => variable.kind,
              "type" => variable.type,
              "description" => variable.description,
              "required" => variable.required,
              "has_value" => not is_nil(variable.value)
            }
          end),
        "dropped_values" => result.dropped_bindings,
        "waiting_on_an_operator" => result.unbound
      }
    else
      {:error, %Ecto.Changeset{} = changeset} -> SkillAuthoring.error(changeset)
      {:error, error} -> error
    end
  end

  def run(_args), do: SkillAuthoring.error("slug and a variables array are both required.")

  @impl true
  def mutating?(_args), do: true
end

defmodule Echo.Agents.Tools.ListSkills do
  @behaviour Echo.Agents.ToolBackend

  @impl true
  def declaration do
    %{
      "name" => "list_skills",
      "description" =>
        "Lists the skills that already exist, so you can check a slug is free or read one back.",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }
  end

  @impl true
  def run(_args) do
    %{
      "skills" =>
        Enum.map(Echo.Skills.list_skills(), fn skill ->
          %{
            "slug" => skill.slug,
            "name" => skill.name,
            "description" => skill.description,
            "enabled" => skill.enabled
          }
        end)
    }
  end

  @impl true
  def mutating?(_args), do: false
end

defmodule Echo.Agents.Tools.GetSkill do
  @behaviour Echo.Agents.ToolBackend

  alias Echo.Agents.Tools.SkillAuthoring

  @impl true
  def declaration do
    %{
      "name" => "get_skill",
      "description" =>
        "Reads one skill back in full, including its instructions and declared variables.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"slug" => %{"type" => "string"}},
        "required" => ["slug"]
      }
    }
  end

  @impl true
  def run(%{"slug" => slug}) do
    case SkillAuthoring.fetch(slug) do
      {:ok, skill} ->
        variables =
          Enum.map(Echo.Skills.list_variables(skill), fn variable ->
            %{
              "name" => variable.name,
              "kind" => variable.kind,
              "type" => variable.type,
              "description" => variable.description,
              "required" => variable.required,
              "has_value" => not is_nil(variable.value)
            }
          end)

        skill |> SkillAuthoring.render() |> Map.put("variables", variables)

      {:error, error} ->
        error
    end
  end

  def run(_args), do: SkillAuthoring.error("slug is required.")

  @impl true
  def mutating?(_args), do: false
end
