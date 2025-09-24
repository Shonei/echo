defmodule Echo.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :metadata, :binary
      add :type, :string, null: false, default: "user"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create index(:users, [:type])
    create index(:users, [:inserted_at])
  end
end
