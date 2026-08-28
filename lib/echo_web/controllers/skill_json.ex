defmodule EchoWeb.SkillJSON do
  alias Echo.Skills.Skill

  @doc """
  Renders a list of skills.
  """
  def index(%{skills: skills}) do
    %{data: for(skill <- skills, do: data(skill))}
  end

  @doc """
  Renders a single skill.
  """
  def show(%{skill: skill}) do
    %{data: data(skill)}
  end

  defp data(%Skill{} = skill) do
    %{
      id: skill.id,
      slug: skill.slug,
      name: skill.name,
      description: skill.description,
      instructions: skill.instructions,
      tools: skill.tools,
      # Reported as stored rather than resolved, so the API says what the row
      # says: null means the default, Gemini.
      provider: skill.provider,
      model: skill.model,
      temperature: skill.temperature,
      max_output_tokens: skill.max_output_tokens,
      enabled: skill.enabled,
      created_at: skill.inserted_at,
      updated_at: skill.updated_at
    }
  end
end
