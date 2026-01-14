defmodule Echo.ContentTest do
  use Echo.DataCase

  alias Echo.Content

  describe "blogs" do
    alias Echo.Content.Blog

    import Echo.ContentFixtures

    @invalid_attrs %{status: nil, title: nil, slug: nil}

    test "list_blogs/0 returns all blogs" do
      blog = blog_fixture()
      [listed_blog] = Content.list_blogs()
      assert listed_blog.id == blog.id
    end

    test "get_blog!/1 returns the blog with given id" do
      blog = blog_fixture()
      got_blog = Content.get_blog!(blog.id)
      assert got_blog.id == blog.id
    end

    test "create_blog/1 with valid data creates a blog" do
      valid_attrs = %{status: "draft", title: "some title", slug: "some slug"}

      assert {:ok, %Blog{} = blog} = Content.create_blog(valid_attrs)
      assert blog.status == "draft"
      assert blog.title == "some title"
      assert blog.slug == "some slug"
    end

    test "create_blog/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Content.create_blog(@invalid_attrs)
    end

    test "update_blog/2 with valid data updates the blog" do
      blog = blog_fixture()
      update_attrs = %{status: "public", title: "some updated title", slug: "some updated slug"}

      assert {:ok, %Blog{} = blog} = Content.update_blog(blog, update_attrs)
      assert blog.status == "public"
      assert blog.title == "some updated title"
      assert blog.slug == "some updated slug"
    end

    test "update_blog/2 with invalid data returns error changeset" do
      blog = blog_fixture()
      assert {:error, %Ecto.Changeset{}} = Content.update_blog(blog, @invalid_attrs)
      assert Content.get_blog!(blog.id).title == blog.title
    end

    test "delete_blog/1 deletes the blog" do
      blog = blog_fixture()
      assert {:ok, %Blog{}} = Content.delete_blog(blog)
      assert_raise Ecto.NoResultsError, fn -> Content.get_blog!(blog.id) end
    end

    test "change_blog/1 returns a blog changeset" do
      blog = blog_fixture()
      assert %Ecto.Changeset{} = Content.change_blog(blog)
    end
  end

  describe "blog_revisions" do
    alias Echo.Content.Revision

    import Echo.ContentFixtures

    @invalid_attrs %{version: nil, content: nil, note: nil}

    test "list_blog_revisions/0 returns all blog_revisions" do
      revision = revision_fixture()
      revisions = Content.list_blog_revisions()
      assert Enum.any?(revisions, fn r -> r.id == revision.id end)
    end

    test "get_revision!/1 returns the revision with given id" do
      revision = revision_fixture()
      assert Content.get_revision!(revision.id) == revision
    end

    test "create_revision/1 with valid data creates a revision" do
      valid_attrs = %{version: 42, content: "some content", note: "some note"}

      assert {:ok, %Revision{} = revision} = Content.create_revision(valid_attrs)
      assert revision.version == 42
      assert revision.content == "some content"
      assert revision.note == "some note"
    end

    test "create_revision/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Content.create_revision(@invalid_attrs)
    end

    test "update_revision/2 with valid data updates the revision" do
      revision = revision_fixture()
      update_attrs = %{version: 43, content: "some updated content", note: "some updated note"}

      assert {:ok, %Revision{} = revision} = Content.update_revision(revision, update_attrs)
      assert revision.version == 43
      assert revision.content == "some updated content"
      assert revision.note == "some updated note"
    end

    test "update_revision/2 with invalid data returns error changeset" do
      revision = revision_fixture()
      assert {:error, %Ecto.Changeset{}} = Content.update_revision(revision, @invalid_attrs)
      assert revision == Content.get_revision!(revision.id)
    end

    test "delete_revision/1 deletes the revision" do
      revision = revision_fixture()
      assert {:ok, %Revision{}} = Content.delete_revision(revision)
      assert_raise Ecto.NoResultsError, fn -> Content.get_revision!(revision.id) end
    end

    test "change_revision/1 returns a revision changeset" do
      revision = revision_fixture()
      assert %Ecto.Changeset{} = Content.change_revision(revision)
    end
  end
end
