defmodule EchoWeb.SkillController do
  use EchoWeb, :controller

  alias Echo.Skills
  alias Echo.Skills.Skill

  action_fallback EchoWeb.FallbackController

  def index(conn, params) do
    render(conn, :index, skills: Skills.list_skills(list_filters(params)))
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, skill: Skills.get_skill_by_id_or_slug!(id))
  end

  def create(conn, %{"skill" => skill_params}) do
    with {:ok, %Skill{} = skill} <- Skills.create_skill(skill_params) do
      conn
      |> put_status(:created)
      |> render(:show, skill: skill)
    end
  end

  def create(_conn, _params), do: {:error, :missing_param, "skill"}

  # A `provider` or `instructions` key here is ignored rather than rejected,
  # exactly as a `content` key is on `PUT /blogs/:id`: `update_changeset/2`
  # never casts either.
  def update(conn, %{"id" => id, "skill" => skill_params}) do
    skill = Skills.get_skill_by_id_or_slug!(id)

    with {:ok, %Skill{} = skill} <- Skills.update_skill(skill, skill_params) do
      render(conn, :show, skill: skill)
    end
  end

  def update(_conn, %{"id" => _id}), do: {:error, :missing_param, "skill"}

  def update_instructions(conn, %{"skill_id" => id, "instructions" => instructions}) do
    skill = Skills.get_skill_by_id_or_slug!(id)

    with {:ok, %Skill{} = skill} <- Skills.update_skill_instructions(skill, instructions) do
      render(conn, :show, skill: skill)
    end
  end

  def update_instructions(_conn, %{"skill_id" => _id}),
    do: {:error, :missing_param, "instructions"}

  def delete(conn, %{"id" => id}) do
    skill = Skills.get_skill_by_id_or_slug!(id)

    with {:ok, %Skill{}} <- Skills.delete_skill(skill) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  Queues a run and answers 202 with it. The model is never waited on: the run is
  readable at `GET /skills/:skill_id/runs/:id`, and its conversation at
  `/ai-messages`.
  """
  def run(conn, %{"skill_id" => id} = params) do
    skill = Skills.get_skill_by_id_or_slug!(id)

    with {:ok, input} <- validate_input(params["input"]),
         {:ok, run} <- Skills.run_skill(skill, input) do
      conn
      |> put_status(:accepted)
      |> put_view(json: EchoWeb.SkillRunJSON)
      |> render(:show, run: run)
    end
  end

  defp validate_input(nil), do: {:ok, %{}}
  defp validate_input(input) when is_map(input), do: {:ok, input}
  defp validate_input(_other), do: {:error, :invalid_input}

  defp list_filters(%{"enabled" => "true"}), do: %{enabled: true}
  defp list_filters(%{"enabled" => "false"}), do: %{enabled: false}
  defp list_filters(_params), do: %{}
end
