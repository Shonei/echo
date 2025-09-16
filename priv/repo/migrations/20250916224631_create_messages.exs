defmodule Echo.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :content, :text, null: false
      add :room, :string, null: false
      add :user_id, :string, null: false
      add :username, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:room])
    create index(:messages, [:inserted_at])
    create index(:messages, [:room, :inserted_at])
  end
end
