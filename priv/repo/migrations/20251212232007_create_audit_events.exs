defmodule Echo.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :session_hash, :string
      add :type, :string
      add :created_at, :utc_datetime
      add :payload, :binary
      add :content, :string

      timestamps(type: :utc_datetime)
    end
  end
end
