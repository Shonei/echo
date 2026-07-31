defmodule Echo.Content do
  @moduledoc """
  The Content context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.Content.Blog
  alias Echo.Content.Revision

  @auto_snapshot_note "Automatic snapshot before save"

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

  A numeric identifier is tried as an ID first and then as a slug, so a blog
  whose slug happens to be all digits stays reachable.

  Raises `Ecto.NoResultsError` if the Blog does not exist.
  """
  def get_blog_by_id_or_slug!(identifier) do
    case Integer.parse(identifier) do
      {id, ""} -> Repo.get(Blog, id) || Repo.get_by!(Blog, slug: identifier)
      _ -> Repo.get_by!(Blog, slug: identifier)
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

  A `content` key in `attrs` is ignored: content is saved through
  `update_blog_content/2` so it always gets snapshotted first.
  """
  def update_blog_metadata(%Blog{} = blog, attrs) do
    save_blog(blog, Blog.metadata_changeset(blog, attrs))
  end

  @doc """
  Updates a blog's content.
  """
  def update_blog_content(%Blog{} = blog, content) do
    save_blog(blog, Blog.changeset(blog, %{content: content}))
  end

  # Saves a blog, backing up the content it is about to overwrite as a revision.
  # The snapshot and the update share a transaction, so a blog is never left
  # saved without its backup (or vice versa).
  defp save_blog(%Blog{} = blog, changeset) do
    Repo.transaction(fn ->
      with {:ok, _revision} <- snapshot_previous_content(blog, changeset),
           {:ok, saved} <- Repo.update(changeset) do
        saved
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A revision is a backup of the content being replaced, so there is nothing to
  # take when the content is untouched or when the blog had no content yet.
  defp snapshot_previous_content(%Blog{content: previous} = blog, changeset) do
    cond do
      Ecto.Changeset.get_change(changeset, :content) == nil -> {:ok, :unchanged}
      previous in [nil, ""] -> {:ok, :nothing_to_back_up}
      true -> create_snapshot(blog)
    end
  end

  defp create_snapshot(%Blog{} = blog) do
    %Revision{blog_id: blog.id}
    |> Revision.changeset(%{content: blog.content, note: @auto_snapshot_note})
    |> Repo.insert()
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
  Returns the list of revisions for a specific blog, newest first.

  Timestamps only carry second precision, so `id` breaks ties between two saves
  that land in the same second.
  """
  def list_blog_revisions(blog_id) do
    Revision
    |> where([r], r.blog_id == ^blog_id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
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
