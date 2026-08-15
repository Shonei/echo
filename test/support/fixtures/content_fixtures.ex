defmodule Echo.ContentFixtures do
  @moduledoc """
  Factories for content tests. Each call inserts a committed row with unique
  title/slug, safe against leftover data in the long-lived test database.
  """

  alias Echo.Content
  import Echo.DataCase, only: [unique: 1]

  def blog_fixture(attrs \\ %{}) do
    {:ok, blog} =
      attrs
      |> Enum.into(%{
        title: unique("post"),
        slug: unique("post"),
        status: "draft",
        content: "body"
      })
      |> Content.create_blog()

    blog
  end
end
