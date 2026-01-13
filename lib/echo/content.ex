defmodule Echo.Content do
  @moduledoc """
  The Content context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.Content.Blog
  alias Echo.Content.Revision

  @doc """
  Returns the list of blogs with their latest revision content.
  """
  def list_blogs do
    Blog
    |> Repo.all()
    |> Repo.preload(:revisions)
  end

  @doc """
  Gets a single blog with its revisions.
  """
  def get_blog!(id) do
    Blog
    |> Repo.get!(id)
    |> Repo.preload(:revisions)
  end

  @doc """
  Creates a blog with an initial revision.
  """
  def create_blog(attrs) do
    Repo.transaction(fn ->
      blog_changeset = Blog.changeset(%Blog{}, attrs)
      
      case Repo.insert(blog_changeset) do
        {:ok, blog} ->
          content = Map.get(attrs, "content") || Map.get(attrs, :content) || "Start writing..."
          note = Map.get(attrs, "note") || Map.get(attrs, :note) || "Initial draft"
          
          revision_attrs = %{
            content: content,
            note: note,
            version: 1,
            blog_id: blog.id
          }
          
          case create_revision(revision_attrs) do
            {:ok, _revision} -> blog
            {:error, changeset} -> Repo.rollback(changeset)
          end
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Gets the latest revision for a blog.
  """
  def get_latest_revision(blog) do
    Revision
    |> where([r], r.blog_id == ^blog.id)
    |> order_by([r], desc: r.version)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Updates a blog.
  """
  def update_blog(%Blog{} = blog, attrs) do
    Repo.transaction(fn ->
      # Update Blog metadata
      blog_changeset = Blog.changeset(blog, attrs)
      
      updated_blog = case Repo.update(blog_changeset) do
        {:ok, b} -> b
        {:error, changeset} -> Repo.rollback(changeset)
      end

      # Check for content update
      new_content = Map.get(attrs, "content") || Map.get(attrs, :content)
      
      if new_content do
        latest_revision = get_latest_revision(blog)
        current_content = if latest_revision, do: latest_revision.content, else: ""
        
        if new_content != current_content do
          new_version = if latest_revision, do: latest_revision.version + 1, else: 1
          note = Map.get(attrs, "note") || Map.get(attrs, :note) 
          
          revision_attrs = %{
            content: new_content,
            version: new_version,
            blog_id: blog.id,
            note: note
          }
          
          case create_revision(revision_attrs) do
            {:ok, _} -> updated_blog
            {:error, changeset} -> Repo.rollback(changeset)
          end
        else
          updated_blog
        end
      else
        updated_blog
      end
    end)
  end

  @doc """
  Deletes a blog.

  ## Examples

      iex> delete_blog(blog)
      {:ok, %Blog{}}

      iex> delete_blog(blog)
      {:error, %Ecto.Changeset{}}

  """
  def delete_blog(%Blog{} = blog) do
    # Delete associated revisions first
    from(r in Revision, where: r.blog_id == ^blog.id) |> Repo.delete_all()
    Repo.delete(blog)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking blog changes.

  ## Examples

      iex> change_blog(blog)
      %Ecto.Changeset{data: %Blog{}}

  """
  def change_blog(%Blog{} = blog, attrs \\ %{}) do
    Blog.changeset(blog, attrs)
  end

  
  @doc """
  Returns the list of blog_revisions.

  ## Examples

      iex> list_blog_revisions()
      [%Revision{}, ...]

  """
  def list_blog_revisions do
    Repo.all(Revision)
  end

  @doc """
  Gets a single revision.

  Raises `Ecto.NoResultsError` if the Revision does not exist.

  ## Examples

      iex> get_revision!(123)
      %Revision{}

      iex> get_revision!(456)
      ** (Ecto.NoResultsError)

  """
  def get_revision!(id), do: Repo.get!(Revision, id)

  @doc """
  Creates a revision.

  ## Examples

      iex> create_revision(%{field: value})
      {:ok, %Revision{}}

      iex> create_revision(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_revision(attrs) do
    %Revision{}
    |> Revision.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a revision.

  ## Examples

      iex> update_revision(revision, %{field: new_value})
      {:ok, %Revision{}}

      iex> update_revision(revision, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_revision(%Revision{} = revision, attrs) do
    revision
    |> Revision.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a revision.

  ## Examples

      iex> delete_revision(revision)
      {:ok, %Revision{}}

      iex> delete_revision(revision)
      {:error, %Ecto.Changeset{}}

  """
  def delete_revision(%Revision{} = revision) do
    Repo.delete(revision)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking revision changes.

  ## Examples

      iex> change_revision(revision)
      %Ecto.Changeset{data: %Revision{}}

  """
  def change_revision(%Revision{} = revision, attrs \\ %{}) do
    Revision.changeset(revision, attrs)
  end
end
