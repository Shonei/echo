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
    latest_revision = if Ecto.assoc_loaded?(blog.revisions) do
      List.first(Enum.sort_by(blog.revisions, & &1.version, :desc))
    else
      nil
    end

    %{
      id: blog.id,
      title: blog.title,
      slug: blog.slug,
      status: blog.status,
      content: if(latest_revision, do: latest_revision.content, else: nil),
      current_version: if(latest_revision, do: latest_revision.version, else: nil),
      revisions_count: if(Ecto.assoc_loaded?(blog.revisions), do: length(blog.revisions), else: 0),
      created_at: blog.inserted_at,
      updated_at: blog.updated_at
    }
  end
end
