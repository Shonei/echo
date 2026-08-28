defmodule Echo.Skills.Run do
  use Ecto.Schema
  import Ecto.Changeset

  # A log and an index, not a state machine anyone recovers from. The
  # conversation is where the work is actually recorded; `session_id` is the
  # join to it, readable at /ai-messages/:session_id.
  schema "skill_runs" do
    # Plain integer, no assoc: there is no triggers table yet.
    field :trigger_id, :id
    field :session_id, :string
    field :status, :string, default: "queued"
    field :input, :map, default: %{}
    field :result, :string
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :skill, Echo.Skills.Skill

    timestamps(type: :utc_datetime)
  end

  # `awaiting_approval` is a run parked on a gated tool call.
  @statuses ~w(queued running awaiting_approval succeeded failed)

  @doc """
  Insert. `skill_id` is structural, set by the context and never taken from
  user input, so it is not cast here -- the same rule
  `Echo.Content.Revision` follows for `blog_id`.
  """
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [:trigger_id, :input, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:skill_id)
  end

  @doc """
  Everything the runner writes as a run moves along.
  """
  def progress_changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :session_id, :result, :error, :started_at, :finished_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses
end
