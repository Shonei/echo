defmodule EchoWeb.BlogControllerTest do
  use EchoWeb.ConnCase, async: false

  alias Echo.Content

  defp data(conn, status \\ 200), do: json_response(conn, status)["data"]
  defp errors(conn, status), do: json_response(conn, status)["errors"]
  defp slugs(conn), do: conn |> data() |> Enum.map(& &1["slug"])

  describe "authentication" do
    test "write endpoints reject anonymous callers", %{conn: conn} do
      blog = blog_fixture()

      assert json_response(post(conn, "/api/v1/blogs", %{"blog" => %{}}), 401)
      assert json_response(put(conn, "/api/v1/blogs/#{blog.id}", %{"blog" => %{}}), 401)

      assert json_response(
               put(conn, "/api/v1/blogs/#{blog.id}/content", %{"content" => "x"}),
               401
             )

      assert json_response(delete(conn, "/api/v1/blogs/#{blog.id}"), 401)
      assert json_response(get(conn, "/api/v1/blogs/#{blog.id}/revisions"), 401)
    end

    test "the session cookie does not stand in for the bearer token", %{conn: conn} do
      blog = blog_fixture()

      authed = put(authenticate(conn), "/api/v1/blogs/#{blog.id}/content", %{"content" => "one"})
      assert json_response(authed, 200)

      # recycle/1 copies `authorization` by default, so pass [] to drop it.
      replayed =
        put(recycle(authed, []), "/api/v1/blogs/#{blog.id}/content", %{"content" => "two"})

      assert json_response(replayed, 401)
      assert Content.get_blog!(blog.id).content == "one"
    end
  end

  describe "GET /api/v1/blogs" do
    test "anonymous callers see only public blogs", %{conn: conn} do
      public = blog_fixture(%{status: "public"})
      draft = blog_fixture(%{status: "draft"})
      private = blog_fixture(%{status: "private"})

      listed = slugs(get(conn, "/api/v1/blogs"))

      assert public.slug in listed
      refute draft.slug in listed
      refute private.slug in listed
    end

    test "anonymous callers cannot opt into drafts via the status param", %{conn: conn} do
      draft = blog_fixture(%{status: "draft"})

      refute draft.slug in slugs(get(conn, "/api/v1/blogs?status=draft"))
    end

    test "authenticated callers see every status", %{conn: conn} do
      public = blog_fixture(%{status: "public"})
      draft = blog_fixture(%{status: "draft"})
      private = blog_fixture(%{status: "private"})

      listed = slugs(get(authenticate(conn), "/api/v1/blogs"))

      assert public.slug in listed
      assert draft.slug in listed
      assert private.slug in listed
    end

    test "authenticated callers can filter by status", %{conn: conn} do
      public = blog_fixture(%{status: "public"})
      draft = blog_fixture(%{status: "draft"})

      listed = slugs(get(authenticate(conn), "/api/v1/blogs?status=draft"))

      assert draft.slug in listed
      refute public.slug in listed
    end
  end

  describe "GET /api/v1/blogs/:id" do
    test "serves a public blog by slug or numeric id", %{conn: conn} do
      blog = blog_fixture(%{status: "public", description: "hello"})

      by_slug = data(get(conn, "/api/v1/blogs/#{blog.slug}"))
      by_id = data(get(conn, "/api/v1/blogs/#{blog.id}"))

      assert by_slug["id"] == blog.id
      assert by_id["id"] == blog.id
      assert by_slug["description"] == "hello"
      assert by_slug["tags"] == %{}
    end

    test "an all-digit slug is reachable", %{conn: conn} do
      slug = unique_digits()
      blog = blog_fixture(%{slug: slug, status: "public"})

      assert data(get(conn, "/api/v1/blogs/#{slug}"))["id"] == blog.id
    end

    test "hides draft and private blogs from anonymous callers", %{conn: conn} do
      draft = blog_fixture(%{status: "draft"})
      private = blog_fixture(%{status: "private"})

      assert json_response(get(conn, "/api/v1/blogs/#{draft.slug}"), 404)
      assert json_response(get(conn, "/api/v1/blogs/#{draft.id}"), 404)
      assert json_response(get(conn, "/api/v1/blogs/#{private.slug}"), 404)
    end

    test "serves draft and private blogs to an authenticated caller", %{conn: conn} do
      draft = blog_fixture(%{status: "draft"})
      private = blog_fixture(%{status: "private"})
      conn = authenticate(conn)

      assert data(get(conn, "/api/v1/blogs/#{draft.slug}"))["content"] == "body"
      assert data(get(conn, "/api/v1/blogs/#{private.slug}"))["status"] == "private"
    end

    test "missing blog is 404", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/api/v1/blogs/#{unique("missing")}")
      end
    end
  end

  describe "POST /api/v1/blogs" do
    test "creates a blog and defaults status to draft", %{conn: conn} do
      slug = unique("new-post")
      title = unique("title")

      body =
        authenticate(conn)
        |> post("/api/v1/blogs", %{
          "blog" => %{
            "title" => title,
            "slug" => slug,
            "content" => "hello",
            "description" => "a post",
            "icon" => "icon.png",
            "cover_image" => "cover.png",
            "tags" => %{"lang" => "elixir"}
          }
        })
        |> data(201)

      assert body["title"] == title
      assert body["slug"] == slug
      assert body["status"] == "draft"
      assert body["content"] == "hello"
      assert body["description"] == "a post"
      assert body["icon"] == "icon.png"
      assert body["cover_image"] == "cover.png"
      assert body["tags"] == %{"lang" => "elixir"}

      shown = data(get(authenticate(conn), "/api/v1/blogs/#{body["id"]}"))
      assert shown["slug"] == slug
      assert shown["tags"] == %{"lang" => "elixir"}
    end

    test "rejects a duplicate slug", %{conn: conn} do
      taken = blog_fixture()

      conn =
        post(authenticate(conn), "/api/v1/blogs", %{
          "blog" => %{"title" => unique("post"), "slug" => taken.slug}
        })

      assert errors(conn, 422)["slug"]
    end

    test "rejects an unroutable slug", %{conn: conn} do
      conn =
        post(authenticate(conn), "/api/v1/blogs", %{
          "blog" => %{"title" => unique("post"), "slug" => "Not A Slug"}
        })

      assert errors(conn, 422)["slug"]
    end

    test "rejects tags that are not a map of strings", %{conn: conn} do
      slug = unique("bad-tags")

      conn =
        post(authenticate(conn), "/api/v1/blogs", %{
          "blog" => %{
            "title" => unique("post"),
            "slug" => slug,
            "tags" => "tech,elixir"
          }
        })

      assert errors(conn, 422)["tags"]

      assert_raise Ecto.NoResultsError, fn ->
        Content.get_blog_by_id_or_slug!(slug)
      end
    end

    test "rejects a missing title", %{conn: conn} do
      conn =
        post(authenticate(conn), "/api/v1/blogs", %{
          "blog" => %{"slug" => unique("post")}
        })

      assert errors(conn, 422)["title"]
    end
  end

  describe "PUT /api/v1/blogs/:id" do
    test "updates metadata and ignores a content key", %{conn: conn} do
      blog = blog_fixture(%{content: "original", status: "draft"})

      body =
        authenticate(conn)
        |> put("/api/v1/blogs/#{blog.id}", %{
          "blog" => %{
            "title" => "Renamed",
            "status" => "public",
            "description" => "updated",
            "content" => "sneaky",
            "tags" => %{"topic" => "elixir"}
          }
        })
        |> data()

      assert body["title"] == "Renamed"
      assert body["status"] == "public"
      assert body["description"] == "updated"
      assert body["content"] == "original"
      assert body["tags"] == %{"topic" => "elixir"}
      assert Content.list_blog_revisions(blog.id) == []
    end

    test "requires a blog key", %{conn: conn} do
      blog = blog_fixture()
      conn = put(authenticate(conn), "/api/v1/blogs/#{blog.id}", %{"title" => "oops"})

      assert json_response(conn, 400) == %{"errors" => %{"blog" => ["is required"]}}
    end

    test "rejects a duplicate slug", %{conn: conn} do
      taken = blog_fixture()
      blog = blog_fixture()

      conn =
        put(authenticate(conn), "/api/v1/blogs/#{blog.id}", %{
          "blog" => %{"slug" => taken.slug}
        })

      assert errors(conn, 422)["slug"]
      assert Content.get_blog!(blog.id).slug == blog.slug
    end

    test "rejects tags that are not a map of strings", %{conn: conn} do
      blog = blog_fixture()

      conn =
        put(authenticate(conn), "/api/v1/blogs/#{blog.id}", %{
          "blog" => %{"tags" => %{"lang" => 1}}
        })

      assert errors(conn, 422)["tags"]
    end
  end

  describe "PUT /api/v1/blogs/:id/content" do
    test "updates content and snapshots the previous version", %{conn: conn} do
      blog = blog_fixture(%{content: "v1"})
      conn = authenticate(conn)

      assert data(put(conn, "/api/v1/blogs/#{blog.id}/content", %{"content" => "v2"}))[
               "content"
             ] == "v2"

      assert data(put(conn, "/api/v1/blogs/#{blog.id}/content", %{"content" => "v3"}))[
               "content"
             ] == "v3"

      revisions = data(get(conn, "/api/v1/blogs/#{blog.id}/revisions"))
      assert Enum.map(revisions, & &1["content"]) == ["v2", "v1"]
      assert hd(revisions)["note"] == "Automatic snapshot before save"
      refute hd(revisions) |> Map.has_key?("version")
    end

    test "requires a content key", %{conn: conn} do
      blog = blog_fixture()
      conn = put(authenticate(conn), "/api/v1/blogs/#{blog.id}/content", %{"body" => "oops"})

      assert json_response(conn, 400) == %{"errors" => %{"content" => ["is required"]}}
    end

    test "rejects content that is not a string", %{conn: conn} do
      blog = blog_fixture(%{content: "safe"})

      conn =
        put(authenticate(conn), "/api/v1/blogs/#{blog.id}/content", %{"content" => %{"a" => 1}})

      assert errors(conn, 422)["content"]
      assert Content.get_blog!(blog.id).content == "safe"
    end
  end

  describe "DELETE /api/v1/blogs/:id" do
    test "removes the blog and its revisions", %{conn: conn} do
      blog = blog_fixture(%{content: "v1", status: "public"})
      {:ok, _} = Content.update_blog_content(blog, "v2")
      conn = authenticate(conn)

      assert delete(conn, "/api/v1/blogs/#{blog.id}") |> response(204)

      assert_error_sent 404, fn ->
        get(conn, "/api/v1/blogs/#{blog.id}")
      end

      assert_error_sent 404, fn ->
        get(build_conn(), "/api/v1/blogs/#{blog.slug}")
      end

      assert Content.list_blog_revisions(blog.id) == []
    end
  end

  describe "GET /api/v1/blogs/:id/revisions" do
    test "returns an empty list when nothing has been snapshotted", %{conn: conn} do
      blog = blog_fixture()

      assert data(get(authenticate(conn), "/api/v1/blogs/#{blog.id}/revisions")) == []
    end

    test "creating a revision by hand is not routable", %{conn: conn} do
      blog = blog_fixture()

      conn =
        post(authenticate(conn), "/api/v1/blogs/#{blog.id}/revisions", %{
          "revision" => %{"content" => "manual"}
        })

      assert conn.status == 404
      assert Content.list_blog_revisions(blog.id) == []
    end
  end
end
