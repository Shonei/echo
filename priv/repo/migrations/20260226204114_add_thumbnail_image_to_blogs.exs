defmodule Echo.Repo.Migrations.AddThumbnailImageToBlogs do
  use Ecto.Migration

  def change do
    alter table(:blogs) do
      add :thumbnail_image, :string
    end
  end
end
