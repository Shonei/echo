defmodule EchoWeb.BlogJSON do
  alias Echo.Content.Blog

  @doc """
  Renders a list of blogs.
  """
  def index(%{blogs: blogs}) do
    %{data: for(blog <- blogs, do: data(blog))}
  end

  @doc """
  Renders a single blog.
  """
  def show(%{blog: blog}) do
    %{data: data(blog)}
  end

  defp data(%Blog{} = blog) do
    %{
      id: blog.id,
      title: blog.title,
      slug: blog.slug,
      status: blog.status,
      content: blog.content,
      icon: blog.icon,
      background_image: blog.background_image,
      cover_image: blog.cover_image,
      description: blog.description,
      tags: parse_tags(blog.tags),
      created_at: blog.inserted_at,
      updated_at: blog.updated_at
    }
  end

  defp parse_tags(nil), do: %{}

  defp parse_tags(tags) when is_binary(tags) do
    case Jason.decode(tags) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_tags(_), do: %{}
end
