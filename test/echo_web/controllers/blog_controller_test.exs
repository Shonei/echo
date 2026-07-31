defmodule EchoWeb.BlogControllerTest do
  use EchoWeb.ConnCase, async: false

  alias Echo.Content

  defp blog_fixture(attrs \\ %{}) do
    {:ok, blog} =
      attrs
      |> Enum.into(%{
        title: "A post",
        slug: "a-post-#{System.unique_integer([:positive])}",
        status: "draft",
        content: "body"
      })
      |> Content.create_blog()

    blog
  end

  defp slugs(conn), do: conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["slug"])

  describe "index visibility" do
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
      assert slugs(get(conn, "/api/v1/blogs?status=draft")) == []
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

    test "authenticated callers can still filter by status", %{conn: conn} do
      public = blog_fixture(%{status: "public"})
      draft = blog_fixture(%{status: "draft"})

      listed = slugs(get(authenticate(conn), "/api/v1/blogs?status=draft"))

      assert draft.slug in listed
      refute public.slug in listed
    end
  end

  describe "show visibility" do
    test "serves a public blog by slug to anyone", %{conn: conn} do
      blog = blog_fixture(%{status: "public"})

      assert json_response(get(conn, "/api/v1/blogs/#{blog.slug}"), 200)["data"]["slug"] ==
               blog.slug
    end

    test "hides a draft from anonymous callers", %{conn: conn} do
      blog = blog_fixture(%{status: "draft"})

      assert json_response(get(conn, "/api/v1/blogs/#{blog.slug}"), 404)
      assert json_response(get(conn, "/api/v1/blogs/#{blog.id}"), 404)
    end

    test "hides a private blog from anonymous callers", %{conn: conn} do
      blog = blog_fixture(%{status: "private"})
      assert json_response(get(conn, "/api/v1/blogs/#{blog.slug}"), 404)
    end

    test "serves a draft to an authenticated caller", %{conn: conn} do
      blog = blog_fixture(%{status: "draft"})

      assert json_response(get(authenticate(conn), "/api/v1/blogs/#{blog.slug}"), 200)["data"][
               "content"
             ] == "body"
    end

    test "an all-digit slug is reachable", %{conn: conn} do
      blog = blog_fixture(%{slug: "2026", status: "public"})
      assert json_response(get(conn, "/api/v1/blogs/2026"), 200)["data"]["id"] == blog.id
    end
  end

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
    end

    test "the session cookie does not stand in for the bearer token", %{conn: conn} do
      blog = blog_fixture()

      authed = put(authenticate(conn), "/api/v1/blogs/#{blog.id}/content", %{"content" => "one"})
      assert json_response(authed, 200)

      # Same connection, cookies retained, Authorization header dropped.
      # recycle/1 copies `authorization` by default, so pass [] to drop it.
      replayed =
        put(recycle(authed, []), "/api/v1/blogs/#{blog.id}/content", %{"content" => "two"})

      assert json_response(replayed, 401)
      assert Content.get_blog!(blog.id).content == "one"
    end
  end

  describe "revisions" do
    test "listing requires authentication", %{conn: conn} do
      blog = blog_fixture(%{status: "public", content: "v1"})
      {:ok, _} = Content.update_blog_content(blog, "v2")

      assert json_response(get(conn, "/api/v1/blogs/#{blog.id}/revisions"), 401)

      body = json_response(get(authenticate(conn), "/api/v1/blogs/#{blog.id}/revisions"), 200)
      assert [%{"content" => "v1", "note" => "Automatic snapshot before save"}] = body["data"]
      refute body["data"] |> hd() |> Map.has_key?("version")
    end

    test "creating one is no longer routable", %{conn: conn} do
      blog = blog_fixture()

      conn =
        post(authenticate(conn), "/api/v1/blogs/#{blog.id}/revisions", %{
          "revision" => %{"content" => "manual"}
        })

      assert conn.status == 404
      assert Content.list_blog_revisions(blog.id) == []
    end

    test "saving content over the API snapshots the previous version", %{conn: conn} do
      blog = blog_fixture(%{content: "original"})

      assert json_response(
               put(authenticate(conn), "/api/v1/blogs/#{blog.id}/content", %{"content" => "new"}),
               200
             )["data"]["content"] == "new"

      assert [%{content: "original"}] = Content.list_blog_revisions(blog.id)
    end
  end

  describe "tags" do
    test "a map round-trips through create", %{conn: conn} do
      body =
        authenticate(conn)
        |> post("/api/v1/blogs", %{
          "blog" => %{
            "title" => "T",
            "slug" => "tagged-#{System.unique_integer([:positive])}",
            "tags" => %{"lang" => "elixir"}
          }
        })
        |> json_response(201)

      assert body["data"]["tags"] == %{"lang" => "elixir"}

      assert json_response(get(authenticate(conn), "/api/v1/blogs/#{body["data"]["id"]}"), 200)[
               "data"
             ]["tags"] == %{"lang" => "elixir"}
    end

    test "create rejects a non-map instead of silently storing it", %{conn: conn} do
      conn =
        post(authenticate(conn), "/api/v1/blogs", %{
          "blog" => %{"title" => "T", "slug" => "bad-tags", "tags" => "tech,elixir"}
        })

      assert json_response(conn, 422)["errors"]["tags"]
      assert Content.list_blogs() |> Enum.all?(&(&1.slug != "bad-tags"))
    end

    test "update rejects a non-map", %{conn: conn} do
      blog = blog_fixture()

      assert json_response(
               put(authenticate(conn), "/api/v1/blogs/#{blog.id}", %{
                 "blog" => %{"tags" => "tech,elixir"}
               }),
               422
             )["errors"]["tags"]
    end
  end

  describe "malformed payloads" do
    test "update without a blog key returns 400", %{conn: conn} do
      blog = blog_fixture()
      conn = put(authenticate(conn), "/api/v1/blogs/#{blog.id}", %{"title" => "oops"})

      assert json_response(conn, 400) == %{"errors" => %{"blog" => ["is required"]}}
    end

    test "update_content without a content key returns 400", %{conn: conn} do
      blog = blog_fixture()
      conn = put(authenticate(conn), "/api/v1/blogs/#{blog.id}/content", %{"body" => "oops"})

      assert json_response(conn, 400) == %{"errors" => %{"content" => ["is required"]}}
    end

    test "content that is not a string returns 422", %{conn: conn} do
      blog = blog_fixture(%{content: "safe"})

      conn =
        put(authenticate(conn), "/api/v1/blogs/#{blog.id}/content", %{"content" => %{"a" => 1}})

      assert json_response(conn, 422)["errors"]["content"]
      assert Content.get_blog!(blog.id).content == "safe"
    end

    test "an unroutable slug returns 422 on create", %{conn: conn} do
      conn =
        post(authenticate(conn), "/api/v1/blogs", %{
          "blog" => %{"title" => "T", "slug" => "Not A Slug"}
        })

      assert json_response(conn, 422)["errors"]["slug"]
    end
  end

  describe "metadata update" do
    test "cannot rewrite content", %{conn: conn} do
      blog = blog_fixture(%{content: "original"})

      body =
        authenticate(conn)
        |> put("/api/v1/blogs/#{blog.id}", %{
          "blog" => %{"title" => "Renamed", "content" => "sneaky"}
        })
        |> json_response(200)

      assert body["data"]["title"] == "Renamed"
      assert body["data"]["content"] == "original"
      assert Content.list_blog_revisions(blog.id) == []
    end
  end
end
