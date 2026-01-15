defmodule Echo.ContentFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Echo.Content` context.
  """

  @doc """
  Generate a blog.
  """
  def blog_fixture(attrs \\ %{}) do
    {:ok, blog} =
      attrs
      |> Enum.into(%{
        slug: "some slug #{System.unique_integer()}",
        status: "draft",
        title: "some title"
      })
      |> Echo.Content.create_blog()

    blog
  end

  @doc """
  Generate a revision.
  """
  def revision_fixture(attrs \\ %{}) do
    # Ensure we have a blog for the revision
    blog_id = Map.get(attrs, :blog_id) || blog_fixture().id

    {:ok, revision} =
      attrs
      |> Enum.into(%{
        content: "some content",
        note: "some note",
        version: 42,
        blog_id: blog_id
      })
      |> Echo.Content.create_revision()

    revision
  end
end
