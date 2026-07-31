defmodule Echo.Repo.Migrations.DropUnusedTables do
  use Ecto.Migration

  # urls, users and tool_configs have no Ecto schema and no references anywhere
  # in lib/. Authentication is config-backed (config :echo, :auth) and the token
  # store is the in-memory Echo.AuthUser GenServer, so the users table is unused
  # despite the name. Dropped on the way to Postgres rather than ported.
  def up do
    # tool_configs first: it holds a foreign key into users.
    drop table(:tool_configs)
    drop table(:users)
    drop table(:urls)
  end

  def down do
    create table(:urls) do
      add :link, :text
      add :title, :string

      timestamps(type: :utc_datetime)
    end

    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :metadata, :text
      add :type, :string, null: false, default: "user"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create index(:users, [:type])
    create index(:users, [:inserted_at])

    create table(:tool_configs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :function_type, :string, null: false
      add :http_method, :string
      add :http_url, :text
      add :description, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:tool_configs, [:user_id])
    create index(:tool_configs, [:function_type])
    create index(:tool_configs, [:user_id, :function_type])
  end
end
