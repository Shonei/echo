defmodule EchoWeb.SkillRunJSON do
  alias Echo.Skills.Run

  @doc """
  Renders a list of runs.
  """
  def index(%{runs: runs}) do
    %{data: for(run <- runs, do: data(run))}
  end

  @doc """
  Renders a single run. This is also the 202 body from starting one, where
  `data.id` is the run id and `session_id` is still null.
  """
  def show(%{run: run}) do
    %{data: data(run)}
  end

  defp data(%Run{} = run) do
    %{
      id: run.id,
      skill_id: run.skill_id,
      trigger_id: run.trigger_id,
      # The conversation, readable at /ai-messages/:session_id. Null until the
      # run's task has started one.
      session_id: run.session_id,
      status: run.status,
      input: run.input,
      result: run.result,
      error: run.error,
      started_at: run.started_at,
      finished_at: run.finished_at,
      created_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end
end
