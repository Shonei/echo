defmodule EchoWeb.SkillRunController do
  use EchoWeb, :controller

  alias Echo.Skills

  action_fallback EchoWeb.FallbackController

  def index(conn, %{"skill_id" => skill_id} = params) do
    skill = Skills.get_skill_by_id_or_slug!(skill_id)
    runs = Skills.list_runs(skill, limit: limit(params))
    render(conn, :index, runs: runs)
  end

  def show(conn, %{"skill_id" => skill_id, "id" => id}) do
    skill = Skills.get_skill_by_id_or_slug!(skill_id)
    render(conn, :show, run: Skills.get_run_for_skill!(skill, id))
  end

  defp limit(%{"limit" => limit}) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} when value > 0 and value <= 200 -> value
      _ -> 50
    end
  end

  defp limit(_params), do: 50
end
