defmodule Echo.Repo.Migrations.RecreateAuditTables do
  use Ecto.Migration

  def change do
    drop table(:audit_events)
    drop table(:audit_sessions)

    create table(:audit_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_hash, :string
      add :system_prompt, :string
      add :created_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create table(:audit_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, references(:audit_sessions, type: :string, on_delete: :delete_all)
      add :type, :string
      add :content, :string
      add :payload, :map
      add :created_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:audit_events, [:session_id])
  end
end
