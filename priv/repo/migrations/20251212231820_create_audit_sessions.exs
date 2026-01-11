defmodule Echo.Repo.Migrations.CreateAuditSessions do
  use Ecto.Migration

  def change do
    create table(:audit_sessions) do
      add :session_hash, :string
      add :system_prompt, :string
      add :created_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
