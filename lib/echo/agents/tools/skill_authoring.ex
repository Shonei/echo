defmodule Echo.Agents.Tools.SkillAuthoring do
  @moduledoc """
  Shared helpers for the tools that write skills.

  Every one of these is a thin wrapper over `Echo.Skills`: it validates nothing
  the context does not, and returns a map rather than raising, so a bad argument
  comes back as something the model can read and correct.

  None of them can reach `tool_config`. What a skill may invoke is a grant an
  operator makes, and withholding the field is a stronger property than
  reviewing each proposed change.
  """

  alias Echo.Skills.Skill

  @doc """
  Renders a skill for a tool result: enough for the agent to see what it wrote,
  and nothing an operator alone should decide.
  """
  def render(%Skill{} = skill) do
    %{
      "slug" => skill.slug,
      "name" => skill.name,
      "description" => skill.description,
      "instructions" => skill.instructions,
      "provider" => skill.provider,
      "model" => skill.model,
      "enabled" => skill.enabled,
      "tools" => Map.keys(skill.tool_config || %{})
    }
  end

  @doc """
  Turns a changeset into an error the model can act on.
  """
  def error(%Ecto.Changeset{} = changeset) do
    messages =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
        end)
      end)
      |> Map.new(fn {field, messages} -> {to_string(field), messages} end)

    %{"error" => "The skill was rejected.", "details" => messages}
  end

  def error(reason) when is_binary(reason), do: %{"error" => reason}

  @doc """
  Looks a skill up by slug, or returns the error to hand back.
  """
  def fetch(slug) when is_binary(slug) do
    case Echo.Skills.get_skill_by_slug(slug) do
      nil -> {:error, error("No skill with slug #{inspect(slug)}.")}
      skill -> {:ok, skill}
    end
  end

  def fetch(_slug), do: {:error, error("slug is required and must be a string.")}
end

defmodule Echo.Agents.Tools.CreateSkill do
  @behaviour Echo.Agents.ToolBackend

  alias Echo.Agents.Tools.SkillAuthoring

  @impl true
  def declaration do
    %{
      "name" => "create_skill",
      "description" =>
        "Creates a new skill: a named, reusable set of instructions that can be run later. " <>
          "Returns the skill, including its slug, which every other skill tool takes. " <>
          "Which tools the skill may use is not set here; an operator grants those.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "slug" => %{
            "type" => "string",
            "description" => "Lowercase letters, numbers and single dashes, e.g. weekly-report."
          },
          "name" => %{"type" => "string", "description" => "A short human-readable name."},
          "description" => %{
            "type" => "string",
            "description" => "One line on what the skill does, for listing and picking."
          },
          "instructions" => %{
            "type" => "string",
            "description" =>
              "The markdown body, used verbatim as the skill's system prompt. " <>
                "Write $.name where a variable's value should appear at run time."
          },
          "provider" => %{
            "type" => "string",
            "description" =>
              "Model backend: gemini (the default) or openrouter. Cannot be changed later.",
            "enum" => ["gemini", "openrouter"]
          },
          "model" => %{"type" => "string", "description" => "Optional model name."}
        },
        "required" => ["slug", "name"]
      }
    }
  end

  @impl true
  def run(args) when is_map(args) do
    case Echo.Skills.create_skill(
           Map.take(args, ~w(slug name description instructions provider model))
         ) do
      {:ok, skill} -> SkillAuthoring.render(skill)
      {:error, changeset} -> SkillAuthoring.error(changeset)
    end
  end

  def run(_args), do: SkillAuthoring.error("Expected an object with at least a slug and a name.")

  @impl true
  def mutating?(_args), do: true
end

defmodule Echo.Agents.Tools.UpdateSkill do
  @behaviour Echo.Agents.ToolBackend

  alias Echo.Agents.Tools.SkillAuthoring

  @impl true
  def declaration do
    %{
      "name" => "update_skill",
      "description" =>
        "Updates a skill's name, description, model or enabled flag. " <>
          "The body is written with update_skill_instructions, the provider cannot change, " <>
          "and the tools a skill may use are granted by an operator, not here.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "slug" => %{"type" => "string", "description" => "Which skill to update."},
          "name" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "model" => %{"type" => "string"},
          "enabled" => %{
            "type" => "boolean",
            "description" => "False stops a trigger firing it; it can still be run by hand."
          }
        },
        "required" => ["slug"]
      }
    }
  end

  @impl true
  def run(%{"slug" => slug} = args) do
    with {:ok, skill} <- SkillAuthoring.fetch(slug),
         {:ok, updated} <-
           Echo.Skills.update_skill(skill, Map.take(args, ~w(name description model enabled))) do
      SkillAuthoring.render(updated)
    else
      {:error, %Ecto.Changeset{} = changeset} -> SkillAuthoring.error(changeset)
      {:error, error} -> error
    end
  end

  def run(_args), do: SkillAuthoring.error("slug is required.")

  @impl true
  def mutating?(_args), do: true
end

defmodule Echo.Agents.Tools.UpdateSkillInstructions do
  @behaviour Echo.Agents.ToolBackend

  alias Echo.Agents.Tools.SkillAuthoring

  @impl true
  def declaration do
    %{
      "name" => "update_skill_instructions",
      "description" =>
        "Replaces a skill's markdown body, which becomes its system prompt verbatim. " <>
          "Write $.name where a variable's value should appear at run time.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "slug" => %{"type" => "string", "description" => "Which skill to write."},
          "instructions" => %{"type" => "string", "description" => "The whole body."}
        },
        "required" => ["slug", "instructions"]
      }
    }
  end

  @impl true
  def run(%{"slug" => slug, "instructions" => instructions}) when is_binary(instructions) do
    with {:ok, skill} <- SkillAuthoring.fetch(slug),
         {:ok, updated} <- Echo.Skills.update_skill_instructions(skill, instructions) do
      SkillAuthoring.render(updated)
    else
      {:error, %Ecto.Changeset{} = changeset} -> SkillAuthoring.error(changeset)
      {:error, error} -> error
    end
  end

  def run(_args), do: SkillAuthoring.error("slug and instructions are both required.")

  @impl true
  def mutating?(_args), do: true
end
