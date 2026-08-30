defmodule Echo.Agents.Tools.RunSkill do
  @behaviour Echo.Agents.ToolBackend

  alias Echo.Agents.Tools.SkillAuthoring
  alias Echo.Skills

  # A run happens in its own task, so this blocks the conversation waiting on it.
  # `Tools.run_all/5` caps that against the turn's remaining time; this is the
  # shorter of the two, so the agent gets "check back later" rather than being
  # cut off, whenever the turn has the time to spare.
  @wait_ms 90_000
  @poll_ms 500

  @terminal ~w(succeeded failed awaiting_approval)

  @impl true
  def declaration do
    %{
      "name" => "run_skill",
      "description" =>
        "Runs a skill and waits for it, so you can test one you just wrote and fix what " <>
          "went wrong. Returns the run's status and its final text. Use this to check a " <>
          "skill works, not to get work done -- if the operator wants the work done, they " <>
          "will run it themselves.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "slug" => %{"type" => "string", "description" => "Which skill to run."},
          "instructions" => %{
            "type" => "string",
            "description" =>
              "Optional text for this run. Fills $.instructions in the body, or becomes the " <>
                "opening message if the body does not use it."
          }
        },
        "required" => ["slug"]
      }
    }
  end

  @impl true
  def run(%{"slug" => slug} = args) do
    with {:ok, skill} <- SkillAuthoring.fetch(slug),
         {:ok, run} <- Skills.run_skill(skill, input(args)) do
      run.id |> await() |> render()
    else
      {:error, {:unbound_variables, names}} ->
        %{
          "error" =>
            "This skill cannot run yet: #{Enum.join(names, ", ")} " <>
              "#{if length(names) == 1, do: "has", else: "have"} no value. " <>
              "Only the operator can set one, so ask them.",
          "waiting_on_an_operator" => names
        }

      {:error, :too_many_runs} ->
        %{"error" => "Too many runs are already in flight. Try again shortly."}

      {:error, %Ecto.Changeset{} = changeset} ->
        SkillAuthoring.error(changeset)

      {:error, error} ->
        error
    end
  end

  def run(_args), do: SkillAuthoring.error("slug is required.")

  defp input(%{"instructions" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> %{}
      trimmed -> %{"instructions" => trimmed}
    end
  end

  defp input(_args), do: %{}

  defp await(run_id, waited \\ 0) do
    run = Skills.get_run!(run_id)

    cond do
      run.status in @terminal -> run
      waited >= @wait_ms -> run
      true -> Process.sleep(@poll_ms) && await(run_id, waited + @poll_ms)
    end
  end

  @doc false
  def render(run) do
    %{
      "run_id" => run.id,
      "status" => run.status,
      "result" => run.result,
      "error" => run.error,
      "session_id" => run.session_id,
      "note" => note(run.status)
    }
  end

  defp note("succeeded"), do: nil

  defp note("awaiting_approval"),
    do: "A tool call is gated and waiting on the operator, so the run stopped part way."

  defp note("failed"), do: "Read the error, fix the skill, and try again."

  defp note(_still_going),
    do: "Still running after #{div(@wait_ms, 1000)}s. Check it later with get_skill_run."

  @impl true
  def mutating?(_args), do: true
end

defmodule Echo.Agents.Tools.GetSkillRun do
  @behaviour Echo.Agents.ToolBackend

  alias Echo.Agents.Tools.RunSkill
  alias Echo.Skills

  @impl true
  def declaration do
    %{
      "name" => "get_skill_run",
      "description" =>
        "Reads one run of a skill: its status, its final text, and any error. " <>
          "Use it to check on a run that had not finished, or to look at an earlier one.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{"type" => "integer", "description" => "The run's id."}
        },
        "required" => ["run_id"]
      }
    }
  end

  @impl true
  def run(%{"run_id" => run_id}) do
    case Skills.get_run(run_id) do
      nil -> %{"error" => "No run with id #{inspect(run_id)}."}
      run -> RunSkill.render(run)
    end
  end

  def run(_args), do: %{"error" => "run_id is required."}

  @impl true
  def mutating?(_args), do: false
end
