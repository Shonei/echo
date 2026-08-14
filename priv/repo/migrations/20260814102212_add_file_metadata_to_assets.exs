defmodule Echo.Repo.Migrations.AddFileMetadataToAssets do
  use Ecto.Migration

  def up do
    alter table(:assets) do
      add :filename, :text
      add :byte_size, :integer
      add :width, :integer
      add :height, :integer
      add :variant, :string
      add :content_hash, :text
    end

    create index(:assets, [:content_hash])
    create index(:assets, [:variant])

    # Infer variant and filename from the storage key. Size, dimensions, and
    # content_hash stay null on existing rows; new uploads fill them in.
    execute """
    UPDATE assets
    SET variant = CASE
      WHEN name ~ '-original\\.[^/]+$' THEN 'original'
      WHEN name ~ '-background\\.[^/]+$' THEN 'background'
      WHEN name ~ '-content\\.[^/]+$' THEN 'content'
      WHEN name ~ '-thumbnail\\.[^/]+$' THEN 'thumbnail'
      ELSE 'original'
    END
    WHERE variant IS NULL
    """

    execute """
    UPDATE assets
    SET filename = regexp_replace(
      regexp_replace(name, '^.*/', ''),
      '-(original|background|content|thumbnail)(\\.[^./]+)$',
      '\\2'
    )
    WHERE filename IS NULL AND name IS NOT NULL
    """
  end

  def down do
    drop index(:assets, [:variant])
    drop index(:assets, [:content_hash])

    alter table(:assets) do
      remove :filename
      remove :byte_size
      remove :width
      remove :height
      remove :variant
      remove :content_hash
    end
  end
end
