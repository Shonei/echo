defmodule Echo.Repo.Migrations.CreateRequests do
  use Ecto.Migration

  def change do
    create table(:requests) do
      add :url_path, :string
      add :method, :string
      add :content_type, :string
      add :body, :binary
      add :headers, :binary
      add :url_query, :binary

      timestamps(type: :utc_datetime)
    end
  end
end
