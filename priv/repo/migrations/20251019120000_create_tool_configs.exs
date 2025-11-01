defmodule Echo.Repo.Migrations.CreateToolConfigs do
  use Ecto.Migration

  def change do
    create table(:tool_configs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :function_type, :string, null: false
      add :http_method, :string
      add :http_url, :string
      add :description, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:tool_configs, [:user_id])
    create index(:tool_configs, [:function_type])
    create index(:tool_configs, [:user_id, :function_type])
  end
end

