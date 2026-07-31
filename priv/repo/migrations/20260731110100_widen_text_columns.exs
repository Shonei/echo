defmodule Echo.Repo.Migrations.WidenTextColumns do
  use Ecto.Migration

  # SQLite ignores varchar lengths and stores every :string as unlimited TEXT.
  # Postgres maps :string to varchar(255) and rejects anything longer, so every
  # column that can realistically hold more than 255 characters is widened here.
  # This has to run before the blog data import, or long values fail to insert.
  #
  # Postgres text and varchar have identical performance characteristics, so
  # there is no cost to being generous.
  def up do
    alter table(:blogs) do
      modify :title, :text
      modify :slug, :text
      modify :description, :text
      # holds a JSON encoded map, see Echo.Content.Blog
      modify :tags, :text
      modify :icon, :text
      modify :background_image, :text
      modify :cover_image, :text
      modify :thumbnail_image, :text
    end

    alter table(:blog_revisions) do
      modify :note, :text
    end

    alter table(:assets) do
      modify :name, :text, null: false
      modify :url, :text, null: false
      modify :url_suffix, :text
    end

    alter table(:chat_room) do
      modify :description, :text
    end

    alter table(:audit_sessions) do
      modify :system_prompt, :text
    end

    alter table(:audit_events) do
      modify :content, :text
    end

    alter table(:requests) do
      modify :url_path, :text
    end

    # body, headers and url_query are declared :binary (bytea on Postgres) but
    # all three actually store JSON text. Postgres has no LIKE operator for
    # bytea, which Echo.Requests.search/1 relies on, so convert them to text.
    # An explicit USING clause is required because bytea does not cast to text
    # implicitly. The table is empty on Postgres, so nothing is reinterpreted.
    for column <- ~w(body headers url_query) do
      execute "ALTER TABLE requests ALTER COLUMN #{column} TYPE text USING #{column}::text"
    end
  end

  def down do
    for column <- ~w(body headers url_query) do
      execute "ALTER TABLE requests ALTER COLUMN #{column} TYPE bytea USING #{column}::bytea"
    end

    alter table(:requests) do
      modify :url_path, :string
    end

    alter table(:audit_events) do
      modify :content, :string
    end

    alter table(:audit_sessions) do
      modify :system_prompt, :string
    end

    alter table(:chat_room) do
      modify :description, :string
    end

    alter table(:assets) do
      modify :name, :string, null: false
      modify :url, :string, null: false
      modify :url_suffix, :string
    end

    alter table(:blog_revisions) do
      modify :note, :string
    end

    alter table(:blogs) do
      modify :title, :string
      modify :slug, :string
      modify :description, :string
      modify :tags, :string
      modify :icon, :string
      modify :background_image, :string
      modify :cover_image, :string
      modify :thumbnail_image, :string
    end
  end
end
