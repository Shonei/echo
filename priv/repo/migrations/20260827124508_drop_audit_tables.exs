defmodule Echo.Repo.Migrations.DropAuditTables do
  use Ecto.Migration

  # The audit subsystem is gone. Its routes were removed in `dd96f93`
  # (2026-03-15), so nothing has written to these tables since; the schemas,
  # JSON view, `AuditAuth` plug and `AUDIT_PASSWORD` config were removed with
  # this migration. It backed a CLI agent that was never wired up to Echo.
  #
  # `down` restores the schema as it stood after `20260110220000` and the
  # `audit_*` parts of `20260731110100` (`system_prompt` and `content` widened
  # to :text) so a rollback through either of those still lines up. It does not
  # restore the rows.
  def up do
    # audit_events first: it holds a foreign key into audit_sessions.
    drop table(:audit_events)
    drop table(:audit_sessions)
  end

  def down do
    create table(:audit_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_hash, :string
      add :system_prompt, :text
      add :created_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create table(:audit_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, references(:audit_sessions, type: :string, on_delete: :delete_all)
      add :type, :string
      add :content, :text
      add :payload, :map
      add :created_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:audit_events, [:session_id])
  end
end
