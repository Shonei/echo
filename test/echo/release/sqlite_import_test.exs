defmodule Echo.Release.SqliteImportTest do
  @moduledoc """
  Exercises the one-off SQLite -> Postgres blog import against a real SQLite
  file built to look like the old production database.
  """
  use Echo.DataCase, async: false

  alias Echo.Content
  alias Echo.Release.SqliteImport
  alias Echo.Storage.Asset

  @long_description String.duplicate("a very long blurb. ", 40)

  setup do
    # System env is global, so make sure one test cannot leak into the next.
    on_exit(fn -> System.delete_env("SKIP_SQLITE_IMPORT") end)
    :ok
  end

  # Builds a SQLite database with the schema as it stands in production, i.e.
  # every :string column is unlimited TEXT and timestamps are ISO8601 strings.
  defp legacy_db!(opts \\ []) do
    path = Path.join(System.tmp_dir!(), "legacy-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    execute!(conn, """
    CREATE TABLE blogs (
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, slug TEXT, status TEXT,
      icon TEXT, background_image TEXT, cover_image TEXT, description TEXT,
      content TEXT, tags TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      thumbnail_image TEXT)
    """)

    execute!(conn, """
    CREATE TABLE blog_revisions (
      id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, note TEXT, version INTEGER,
      blog_id INTEGER, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)
    """)

    execute!(conn, """
    CREATE TABLE assets (
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, url TEXT NOT NULL,
      content_type TEXT NOT NULL, reference_type TEXT, reference_id INTEGER,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL, url_suffix TEXT,
      original_hash TEXT)
    """)

    unless opts[:empty] do
      # Two blogs with non-contiguous ids, to prove ids are preserved rather
      # than reassigned. Timestamps deliberately use both separator styles.
      execute!(conn, """
      INSERT INTO blogs (id, title, slug, status, description, content, tags, thumbnail_image, inserted_at, updated_at)
      VALUES
        (7, 'First', 'first-post', 'public', '#{@long_description}', 'body one',
         '{"lang":"elixir"}', '/blogs/first-thumbnail.jpeg', '2026-01-13T10:00:00', '2026-01-13T11:00:00Z'),
        (9, 'Second', 'second-post', 'draft', NULL, NULL, NULL, NULL,
         '2026-02-01 09:30:00', '2026-02-01 09:30:00')
      """)

      execute!(conn, """
      INSERT INTO blog_revisions (id, content, note, version, blog_id, inserted_at, updated_at)
      VALUES
        (3, 'older body', 'Automatic snapshot before save', 1, 7, '2026-01-13T10:30:00', '2026-01-13T10:30:00'),
        (4, 'newer body', 'Automatic snapshot before save', NULL, 7, '2026-01-13T10:45:00', '2026-01-13T10:45:00')
      """)

      execute!(conn, """
      INSERT INTO assets (id, name, url, content_type, reference_type, reference_id, url_suffix, original_hash, inserted_at, updated_at)
      VALUES
        (2, 'blogs/first-thumbnail.jpeg', 'https://s3.example.com/bucket/blogs/first-thumbnail.jpeg',
         'image/jpeg', 'blog', 7, '/blogs/first-thumbnail.jpeg', 'deadbeef', '2026-01-13T10:05:00', '2026-01-13T10:05:00'),
        (5, 'loose/diagram.png', 'https://s3.example.com/bucket/loose/diagram.png',
         'image/png', NULL, NULL, '/loose/diagram.png', 'cafebabe', '2026-01-14T08:00:00', '2026-01-14T08:00:00')
      """)
    end

    :ok = Exqlite.Sqlite3.close(conn)
    path
  end

  defp execute!(conn, sql) do
    :ok = Exqlite.Sqlite3.execute(conn, sql)
  end

  describe "run/2" do
    test "copies blogs, revisions and assets, preserving ids" do
      path = legacy_db!()

      assert {:ok, counts} = SqliteImport.run(Repo, path: path)
      assert counts == %{"blogs" => 2, "blog_revisions" => 2, "assets" => 2}

      assert [first, second] = Content.list_blogs() |> Enum.sort_by(& &1.id)
      assert first.id == 7
      assert first.slug == "first-post"
      assert first.status == "public"
      assert first.content == "body one"
      assert first.thumbnail_image == "/blogs/first-thumbnail.jpeg"
      assert second.id == 9
      assert second.slug == "second-post"
      refute second.content
    end

    test "keeps values that would overflow varchar(255)" do
      path = legacy_db!()
      assert {:ok, _} = SqliteImport.run(Repo, path: path)

      blog = Content.get_blog_by_id_or_slug!("first-post")
      assert blog.description == @long_description
      assert String.length(blog.description) > 255
      # tags stay a JSON string and decode through the API view as a map
      assert Jason.decode!(blog.tags) == %{"lang" => "elixir"}
    end

    test "converts ISO8601 text timestamps in both separator styles" do
      path = legacy_db!()
      assert {:ok, _} = SqliteImport.run(Repo, path: path)

      first = Content.get_blog_by_id_or_slug!("first-post")
      second = Content.get_blog_by_id_or_slug!("second-post")

      assert first.inserted_at == ~U[2026-01-13 10:00:00Z]
      assert first.updated_at == ~U[2026-01-13 11:00:00Z]
      assert second.inserted_at == ~U[2026-02-01 09:30:00Z]
    end

    test "revisions still resolve to their blog" do
      path = legacy_db!()
      assert {:ok, _} = SqliteImport.run(Repo, path: path)

      revisions = Content.list_blog_revisions(7)
      assert Enum.map(revisions, & &1.content) == ["newer body", "older body"]
      assert Enum.all?(revisions, &(&1.blog_id == 7))
      assert Content.list_blog_revisions(9) == []
    end

    test "assets come across whole, not just the blog-referenced ones" do
      assert {:ok, _} = SqliteImport.run(Repo, path: legacy_db!())

      assets = Repo.all(Asset) |> Enum.sort_by(& &1.id)
      assert Enum.map(assets, & &1.id) == [2, 5]
      assert Enum.map(assets, & &1.reference_id) == [7, nil]
      assert hd(assets).original_hash == "deadbeef"
    end

    test "resets sequences so later inserts do not collide" do
      assert {:ok, _} = SqliteImport.run(Repo, path: legacy_db!())

      # Highest imported blog id is 7, revision 4, asset 5. Without setval the
      # sequences would still be at 1 and these would raise on the primary key.
      assert {:ok, blog} =
               Content.create_blog(%{title: "New", slug: "new-post", status: "draft"})

      assert blog.id > 9

      {:ok, blog} =
        Content.update_blog_content(Content.get_blog_by_id_or_slug!("first-post"), "v2")

      assert [%{content: "body one"} | _] = Content.list_blog_revisions(blog.id)

      assert {:ok, asset} =
               %Asset{}
               |> Asset.changeset(%{
                 name: "x.png",
                 url: "https://s3.example.com/bucket/x.png",
                 url_suffix: "/x.png",
                 content_type: "image/png"
               })
               |> Repo.insert()

      assert asset.id > 5
    end

    test "is safe to run twice" do
      path = legacy_db!()
      assert {:ok, %{"blogs" => 2}} = SqliteImport.run(Repo, path: path)

      assert {:ok, %{"blogs" => 0, "blog_revisions" => 0, "assets" => 0}} =
               SqliteImport.run(Repo, path: path)

      assert length(Content.list_blogs()) == 2
    end

    test "handles an empty source database" do
      path = legacy_db!(empty: true)

      assert {:ok, %{"blogs" => 0, "blog_revisions" => 0, "assets" => 0}} =
               SqliteImport.run(Repo, path: path)

      assert Content.list_blogs() == []
    end
  end

  describe "skipping" do
    test "no-ops when the file does not exist" do
      assert {:ok, :skipped} = SqliteImport.run(Repo, path: "/nonexistent/echo.db")
      assert Content.list_blogs() == []
    end

    test "no-ops when no path is configured" do
      assert {:ok, :skipped} = SqliteImport.run(Repo, path: nil)
    end

    test "no-ops when SKIP_SQLITE_IMPORT is set" do
      System.put_env("SKIP_SQLITE_IMPORT", "true")

      assert {:ok, :skipped} = SqliteImport.run(Repo, path: legacy_db!())
      assert Content.list_blogs() == []
    end
  end
end
