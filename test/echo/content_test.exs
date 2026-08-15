defmodule Echo.ContentTest do
  use Echo.DataCase, async: true

  alias Echo.Content
  alias Echo.Content.Blog

  defp blog_fixture(attrs \\ %{}) do
    {:ok, blog} =
      attrs
      |> Enum.into(%{
        title: unique("post"),
        slug: unique("post"),
        status: "draft",
        content: "first draft"
      })
      |> Content.create_blog()

    blog
  end

  describe "update_blog_content/2 automatic revisions" do
    test "snapshots the replaced content" do
      blog = blog_fixture(content: "first draft")

      {:ok, updated} = Content.update_blog_content(blog, "second draft")

      assert updated.content == "second draft"
      assert [revision] = Content.list_blog_revisions(blog.id)
      assert revision.content == "first draft"
      assert revision.blog_id == blog.id
      assert revision.note == "Automatic snapshot before save"
    end

    test "keeps one revision per save, newest first" do
      blog = blog_fixture(content: "v1")

      {:ok, blog} = Content.update_blog_content(blog, "v2")
      {:ok, blog} = Content.update_blog_content(blog, "v3")
      {:ok, _blog} = Content.update_blog_content(blog, "v4")

      assert ["v3", "v2", "v1"] = Enum.map(Content.list_blog_revisions(blog.id), & &1.content)
    end

    test "does not snapshot when the content is unchanged" do
      blog = blog_fixture(content: "same")

      {:ok, _} = Content.update_blog_content(blog, "same")

      assert Content.list_blog_revisions(blog.id) == []
    end

    test "does not snapshot when the blog had no content to back up" do
      blog = blog_fixture(content: nil)

      {:ok, _} = Content.update_blog_content(blog, "first words")

      assert Content.list_blog_revisions(blog.id) == []
    end

    test "rejects content that is not a string without saving or snapshotting" do
      blog = blog_fixture(content: "safe")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Content.update_blog_content(blog, %{"not" => "a string"})

      assert %{content: ["is invalid"]} = errors_on(changeset)
      assert Content.get_blog!(blog.id).content == "safe"
      assert Content.list_blog_revisions(blog.id) == []
    end
  end

  describe "update_blog_metadata/2 automatic revisions" do
    test "ignores a content key, so content cannot bypass the snapshot" do
      blog = blog_fixture(content: "before")

      {:ok, updated} =
        Content.update_blog_metadata(blog, %{"title" => "New title", "content" => "after"})

      assert updated.title == "New title"
      assert updated.content == "before"
      assert Content.list_blog_revisions(blog.id) == []
    end

    test "does not snapshot for a metadata-only update" do
      blog = blog_fixture(content: "before")

      {:ok, updated} = Content.update_blog_metadata(blog, %{"title" => "New title"})

      assert updated.title == "New title"
      assert Content.list_blog_revisions(blog.id) == []
    end

    test "an invalid save leaves no revision behind" do
      taken = blog_fixture()
      blog = blog_fixture(content: "before")

      assert {:error, %Ecto.Changeset{}} =
               Content.update_blog_metadata(blog, %{"slug" => taken.slug, "content" => "after"})

      assert Content.get_blog!(blog.id).content == "before"
      assert Content.list_blog_revisions(blog.id) == []
    end
  end

  describe "get_blog_by_id_or_slug!/1" do
    test "finds a blog by id" do
      blog = blog_fixture()
      assert Content.get_blog_by_id_or_slug!(to_string(blog.id)).id == blog.id
    end

    test "finds a blog by slug" do
      blog = blog_fixture()
      assert Content.get_blog_by_id_or_slug!(blog.slug).id == blog.id
    end

    test "falls back to the slug when a numeric identifier is not an id" do
      slug = unique_digits()
      blog = blog_fixture(slug: slug)
      assert Content.get_blog_by_id_or_slug!(slug).id == blog.id
    end

    test "raises when nothing matches" do
      assert_raise Ecto.NoResultsError, fn ->
        Content.get_blog_by_id_or_slug!(unique("missing"))
      end
    end
  end

  describe "slug validation" do
    test "rejects slugs that could not be routed" do
      for slug <- ["A Post", "a post", "a/b", "trailing-", "Ünïcode"] do
        assert {:error, changeset} =
                 Content.create_blog(%{title: unique("post"), slug: slug, status: "draft"})

        assert %{slug: ["must be lowercase letters, numbers and dashes"]} = errors_on(changeset)
      end
    end

    test "accepts lowercase dashed slugs" do
      slug = unique("a-good-slug")
      assert {:ok, _} = Content.create_blog(%{title: unique("post"), slug: slug, status: "draft"})
    end
  end

  describe "delete_blog/1" do
    test "removes the blog and its revisions" do
      blog = blog_fixture(content: "v1")
      {:ok, blog} = Content.update_blog_content(blog, "v2")
      assert [_] = Content.list_blog_revisions(blog.id)

      assert {:ok, %Blog{}} = Content.delete_blog(blog)
      assert Content.list_blog_revisions(blog.id) == []
    end
  end
end
