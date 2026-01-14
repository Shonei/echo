defmodule Echo.Repo.Migrations.CreateBlogRevisions do
  use Ecto.Migration

  def change do
    create table(:blog_revisions) do
      add :content, :text
      add :note, :string
      add :version, :integer
      add :blog_id, references(:blogs, on_delete: :delete_all)
      timestamps(type: :utc_datetime)
    end

    create index(:blog_revisions, [:blog_id])

    alter table(:blogs) do
      add :revision_id, references(:blog_revisions, on_delete: :nilify_all)
    end

    create index(:blogs, [:revision_id])
  end
end
