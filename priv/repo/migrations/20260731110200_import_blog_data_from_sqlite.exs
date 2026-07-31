defmodule Echo.Repo.Migrations.ImportBlogDataFromSqlite do
  use Ecto.Migration

  # Copies the blogs, their revisions and the assets out of the old SQLite
  # database, which only exists inside the production container — hence a
  # migration at boot rather than a script run from a workstation.
  #
  # No-ops when DATABASE_PATH is unset or points at nothing, so it does nothing
  # in dev, test and CI. Set SKIP_SQLITE_IMPORT=true to boot past it.
  #
  # Delete this migration and Echo.Release.SqliteImport once the cutover is
  # confirmed in production.
  def up do
    {:ok, _result} = Echo.Release.SqliteImport.run(repo())
  end

  def down do
    # Nothing to undo: rolling back would mean deleting the blogs we just
    # rescued. Drop the tables if you truly want to start over.
    :ok
  end
end
