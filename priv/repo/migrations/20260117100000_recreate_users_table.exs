defmodule Echo.Repo.Migrations.RecreateUsersTable do
  use Ecto.Migration

  def change do
    # Drop the existing users table completely
    drop_if_exists table(:users)

    # Create the new users table with the correct schema
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
  end
end

