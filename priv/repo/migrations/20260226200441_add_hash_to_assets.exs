defmodule Echo.Repo.Migrations.AddHashToAssets do
  use Ecto.Migration

  def change do
    alter table(:assets) do
      add :original_hash, :string
    end

    create index(:assets, [:original_hash])
  end
end
