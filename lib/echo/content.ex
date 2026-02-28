defmodule Echo.Content do
  @moduledoc """
  The Content context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.Content.Blog
  alias Echo.Content.Revision

  @doc """
  Returns the list of blogs.

  Right now it only accepts an optional status filter.
  """
  def list_blogs(params \\ %{}) do
    Blog
    |> build_blog_search(params)
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single blog.

  Raises `Ecto.NoResultsError` if the Blog does not exist.
  """
  def get_blog!(id), do: Repo.get!(Blog, id)

  @doc """
  Gets a single blog by ID or slug.

  If the identifier is a numeric string, it will be treated as an ID.
  Otherwise, it will be treated as a slug.

  Raises `Ecto.NoResultsError` if the Blog does not exist.
  """
  def get_blog_by_id_or_slug!(identifier) do
    case Integer.parse(identifier) do
      {id, ""} ->
        # It's a pure integer, look up by ID
        Repo.get!(Blog, id)

      _ ->
        # It's a slug
        Repo.get_by!(Blog, slug: identifier)
    end
  end

  @doc """
  Creates a blog.
  """
  def create_blog(attrs \\ %{}) do
    %Blog{}
    |> Blog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a blog's metadata.
  """
  def update_blog_metadata(%Blog{} = blog, attrs) do
    blog
    |> Blog.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a blog's content.
  """
  def update_blog_content(%Blog{} = blog, content) do
    blog
    |> Ecto.Changeset.change(content: content)
    |> Repo.update()
  end

  @doc """
  Deletes a blog.
  """
  def delete_blog(%Blog{} = blog) do
    Repo.delete(blog)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking blog changes.
  """
  def change_blog(%Blog{} = blog, attrs \\ %{}) do
    Blog.changeset(blog, attrs)
  end

  @doc """
  Returns the list of revisions for a specific blog.
  """
  def list_blog_revisions(blog_id) do
    Revision
    |> where([r], r.blog_id == ^blog_id)
    |> Repo.all()
  end

  @doc """
  Gets a single revision.
  """
  def get_revision!(id), do: Repo.get!(Revision, id)

  @doc """
  Creates a revision for a blog.
  """
  def create_revision(blog_id, attrs) do
    %Revision{blog_id: blog_id}
    |> Revision.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a revision.
  """
  def update_revision(%Revision{} = revision, attrs) do
    revision
    |> Revision.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a revision.
  """
  def delete_revision(%Revision{} = revision) do
    Repo.delete(revision)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking revision changes.
  """
  def change_revision(%Revision{} = revision, attrs \\ %{}) do
    Revision.changeset(revision, attrs)
  end

  defp build_blog_search(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, query when is_binary(status) ->
        from r in query, where: r.status == ^status

      _filter, query ->
        query
    end)
  end
end
