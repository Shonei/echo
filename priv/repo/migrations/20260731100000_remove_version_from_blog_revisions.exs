defmodule Echo.Repo.Migrations.RemoveVersionFromBlogRevisions do
  use Ecto.Migration

  # Revisions are created automatically on save and ordered by their timestamps,
  # so the client-supplied version counter has no writer left.
  def change do
    alter table(:blog_revisions) do
      remove :version, :integer
    end
  end
end
