defmodule Echo.Repo.Migrations.CreateBlogs do
  use Ecto.Migration

  def change do
    create table(:blogs) do
      add :title, :string
      add :slug, :string
      add :status, :string
      add :icon, :string
      add :background_image, :string
      add :cover_image, :string
      add :description, :string

      add :content, :text
      add :tags, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:blogs, [:slug])
  end
end
