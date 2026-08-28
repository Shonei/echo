defmodule Echo.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  # A skill is a preset that lives in a row: markdown instructions, the tools it
  # may use, and generation config.
  #
  # :text rather than :string throughout -- Postgres maps :string to
  # varchar(255) and rejects anything longer. See widen_text_columns.
  def change do
    create table(:skills) do
      add :slug, :text, null: false
      add :name, :text, null: false
      add :description, :text
      add :instructions, :text

      # What this skill may invoke, and how, keyed by tool name:
      # {"http_request": {"gate": "mutations", "config": {...}}}. Declarations
      # are rendered for the provider when a run starts.
      add :tool_config, :map, null: false, default: %{}

      # Fixed at creation: a tool grant is not portable between providers. Null
      # means Gemini.
      add :provider, :text
      add :model, :text
      add :temperature, :float
      add :max_output_tokens, :integer

      # False stops a trigger firing it; a manual run still works.
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:skills, [:slug])

    create table(:skill_runs) do
      add :skill_id, references(:skills, on_delete: :delete_all), null: false

      # Null for a manual run. Plain column until a triggers table exists.
      add :trigger_id, :bigint

      # Null until the runner starts a conversation: start_conversation/1
      # generates the id itself, so the row cannot know it at insert.
      add :session_id, :text

      add :status, :text, null: false, default: "queued"
      add :input, :map, null: false, default: %{}
      add :result, :text
      add :error, :text
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:skill_runs, [:skill_id, :inserted_at])
    create index(:skill_runs, [:session_id])
    # For finding the rows a redeploy stranded in `running`.
    create index(:skill_runs, [:status])

    create table(:skill_variables) do
      add :skill_id, references(:skills, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :kind, :text, null: false
      add :type, :text, null: false, default: "string"
      add :description, :text
      add :required, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0

      # Written by a different path than the declaration above. A `secret` holds
      # its value here in plain text for now.
      add :value, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:skill_variables, [:skill_id, :name])
    create index(:skill_variables, [:skill_id, :position])
  end
end
