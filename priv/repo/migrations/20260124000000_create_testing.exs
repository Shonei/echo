defmodule Echo.Repo.Migrations.CreateTesting do
  use Ecto.Migration

  def change do
    create table(:testing) do
      add :name, :string

      timestamps(type: :utc_datetime)
    end
  end
end

