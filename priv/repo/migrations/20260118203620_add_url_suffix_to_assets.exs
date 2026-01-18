defmodule Echo.Repo.Migrations.AddUrlSuffixToAssets do
  use Ecto.Migration

  def change do
    alter table(:assets) do
      add :url_suffix, :string
    end

    create index(:assets, [:url_suffix])
  end
end
