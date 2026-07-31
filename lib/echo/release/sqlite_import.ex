defmodule Echo.Release.SqliteImport do
  @moduledoc """
  One-off import of blog data from the old SQLite database into Postgres.

  The SQLite file only exists inside the production container, so this runs as
  part of a migration at boot rather than as a script from a workstation. It is
  called by `priv/repo/migrations/20260731110200_import_blog_data_from_sqlite.exs`
  and is safe to delete, along with the `:exqlite` dependency, once the cutover
  is confirmed.

  Only the blogs and what supports them are copied: `blogs`, `blog_revisions`
  and `assets`. Image bytes live in S3, not the database, so they need no
  migration as long as the bucket configuration is unchanged.

  The import no-ops (rather than failing) when there is no SQLite file to read,
  which is what makes it harmless in dev, test and CI.
  """

  require Logger

  alias Echo.Content.Blog
  alias Echo.Content.Revision
  alias Echo.Storage.Asset

  # Rows are inserted through the Ecto schemas so that each value is dumped with
  # the right type — in particular :utc_datetime, which Postgres stores as a
  # timestamp without timezone and would otherwise reject a %DateTime{}.
  #
  # Column lists are explicit because the physical column order in SQLite does
  # not match the schema declaration order: several columns were added by later
  # migrations. Parents come before children so foreign keys always resolve;
  # Postgres enforces them unconditionally, unlike SQLite.
  @tables [
    {Blog,
     ~w(id title slug status icon background_image cover_image thumbnail_image description content tags inserted_at updated_at)a},
    {Revision, ~w(id content note blog_id inserted_at updated_at)a},
    {Asset,
     ~w(id name url url_suffix content_type reference_type reference_id original_hash inserted_at updated_at)a}
  ]

  @timestamp_columns ~w(inserted_at updated_at)a

  @doc """
  Copies blog data from the SQLite database into `repo`.

  Returns `{:ok, counts}` with a row count per table, or `{:ok, :skipped}` when
  there is nothing to import. Accepts `:path` to override `DATABASE_PATH`.
  """
  def run(repo, opts \\ []) do
    path = opts[:path] || System.get_env("DATABASE_PATH")

    cond do
      skip?() ->
        Logger.info("SqliteImport: SKIP_SQLITE_IMPORT is set, skipping blog data import")
        {:ok, :skipped}

      is_nil(path) or path == "" ->
        Logger.info("SqliteImport: DATABASE_PATH is not set, nothing to import")
        {:ok, :skipped}

      not File.exists?(path) ->
        Logger.info("SqliteImport: no SQLite database at #{path}, nothing to import")
        {:ok, :skipped}

      true ->
        Logger.info("SqliteImport: importing blog data from #{path}")
        import_from(repo, path)
    end
  end

  defp skip?, do: System.get_env("SKIP_SQLITE_IMPORT") in ~w(true 1)

  defp import_from(repo, path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path, mode: :readonly)

    try do
      counts =
        Map.new(@tables, fn {schema, columns} ->
          {schema.__schema__(:source), copy_table(repo, conn, schema, columns)}
        end)

      Logger.info("SqliteImport: done, #{inspect(counts)}")
      {:ok, counts}
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp copy_table(repo, conn, schema, columns) do
    table = schema.__schema__(:source)

    if repo.exists?(schema) do
      # A previous attempt already populated this table. Leaving it alone keeps a
      # retry after a partial failure safe.
      Logger.info("SqliteImport: #{table} already has rows, skipping")
      0
    else
      case read_rows(conn, table, columns) do
        [] ->
          Logger.info("SqliteImport: #{table} is empty in SQLite, nothing to copy")
          0

        rows ->
          {count, _} = repo.insert_all(schema, rows)
          reset_sequence(repo, table)
          count
      end
    end
  end

  defp read_rows(conn, table, columns) do
    sql = "SELECT #{Enum.map_join(columns, ", ", &to_string/1)} FROM #{table}"
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
      Enum.map(rows, &build_row(columns, &1))
    after
      Exqlite.Sqlite3.release(conn, statement)
    end
  end

  defp build_row(columns, values) do
    columns
    |> Enum.zip(values)
    |> Enum.map(fn {column, value} -> {column, cast(column, value)} end)
  end

  defp cast(column, value) when column in @timestamp_columns, do: to_datetime(value)
  defp cast(_column, value), do: value

  # ecto_sqlite3 stores :utc_datetime as ISO8601 text. Depending on how a row was
  # written that can be "2026-07-31T10:09:42", the same with a space separator, or
  # either form with a trailing Z and/or fractional seconds.
  defp to_datetime(nil), do: nil
  defp to_datetime(%DateTime{} = value), do: DateTime.truncate(value, :second)

  defp to_datetime(value) when is_binary(value) do
    normalised = String.replace(value, " ", "T", global: false)

    case DateTime.from_iso8601(normalised) do
      {:ok, datetime, _offset} ->
        DateTime.truncate(datetime, :second)

      {:error, :missing_offset} ->
        normalised
        |> NaiveDateTime.from_iso8601!()
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.truncate(:second)
    end
  end

  # Unix timestamps, in case any row was written with a non-default datetime_type.
  defp to_datetime(value) when is_integer(value) do
    value |> DateTime.from_unix!() |> DateTime.truncate(:second)
  end

  # Rows are copied with their original ids so blog_revisions.blog_id and
  # assets.reference_id keep pointing at the right blogs. That leaves the
  # bigserial sequences behind, so the next insert would collide on the primary
  # key unless they are moved past the highest imported id.
  defp reset_sequence(repo, table) do
    repo.query!(
      "SELECT setval(pg_get_serial_sequence($1, 'id'), COALESCE((SELECT MAX(id) FROM #{table}), 1))",
      [table]
    )
  end
end
