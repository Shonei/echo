defmodule Echo.Repo.Migrations.CreateAssets do
  use Ecto.Migration

  def change do
    create table(:assets) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :content_type, :string, null: false
      add :reference_type, :string
      add :reference_id, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:assets, [:reference_type, :reference_id])
    create index(:assets, [:url])
  end
end
