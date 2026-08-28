defmodule Echo.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  # A skill is a preset that lives in a row rather than in a module attribute:
  # markdown instructions, the tool names it may use, and generation config. See
  # designs/skills.md.
  #
  # Integer serial primary keys, matching blogs and ai_messages. The design doc
  # sketches uuid; nothing here needs one (no client-generated ids, single
  # replica) and deviating would leave the schema with two id conventions.
  # That choice propagates: trigger_id, secret_id and connection_id point at
  # tables that arrive in Phases 8, 6 and 7, so they are plain :bigint here and
  # gain `references/2` then, with no type change and no data migration.
  #
  # :text throughout rather than :string. Postgres maps :string to varchar(255)
  # and rejects anything longer -- see 20260731110100_widen_text_columns.
  def change do
    create table(:skills) do
      add :slug, :text, null: false
      add :name, :text, null: false
      add :description, :text
      add :instructions, :text

      # Tool NAMES, never declarations. Rendered for the skill's provider at
      # conversation-start time by Echo.Skills.SkillTools, because a skill has
      # no client and therefore never needs to store a declaration it has no
      # code for.
      add :tools, {:array, :text}, null: false, default: []

      # Fixed at creation, never updatable: capability parity between providers
      # is not portable, so moving a skill would silently drop or substitute
      # part of what it was approved to do. Null means Gemini, per
      # Echo.Agents.Providers.
      add :provider, :text
      add :model, :text
      add :temperature, :float
      add :max_output_tokens, :integer

      # False stops a trigger firing it (Phase 8); a manual run still works, so
      # a skill can be taken off its schedule and still be tested.
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:skills, [:slug])

    create table(:skill_runs) do
      add :skill_id, references(:skills, on_delete: :delete_all), null: false

      # Null for a manual run. Plain column until skill_triggers exists (Phase 8).
      add :trigger_id, :bigint

      # Nullable, and null on purpose between `queued` and `running`:
      # ConversationManager.start_conversation/1 generates the conversation id
      # itself, so the row cannot know it at insert time. The runner fills it in.
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
    # For finding the rows a redeploy stranded. designs/skills.md accepts that a
    # restart mid-run leaves a row in `running`; an operator still has to be
    # able to find them without a sequential scan.
    create index(:skill_runs, [:status])

    create table(:skill_variables) do
      add :skill_id, references(:skills, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :kind, :text, null: false
      add :type, :text, null: false, default: "string"
      add :description, :text
      add :required, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0

      # The binding, written by a different path than the declaration above.
      # A `secret` holds its value here in plain text for now; encrypting this
      # column is a later change, and the only one it should take, because
      # nothing outside `Echo.Skills.Variables` reads it.
      add :value, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:skill_variables, [:skill_id, :name])
    create index(:skill_variables, [:skill_id, :position])
  end
end
