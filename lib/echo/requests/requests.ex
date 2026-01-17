defmodule Echo.Requests do
  @moduledoc """
  The Requests context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.Requests.Request

  @doc """
  Returns the list of requests.

  ## Examples

      iex> list_requests()
      [%Request{}, ...]

  """
  def list_requests do
    Repo.all(Request)
  end

  def count_requests(filters \\ %{}) do
    Request
    |> build_search_query(filters)
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a single request.

  Raises `Ecto.NoResultsError` if the Request does not exist.

  ## Examples

      iex> get_request!(123)
      %Request{}

      iex> get_request!(456)
      ** (Ecto.NoResultsError)

  """
  def get_request!(id), do: Repo.get!(Request, id)

  @doc """
  Creates a request.

  ## Examples

      iex> create_request(%{field: value})
      {:ok, %Request{}}

      iex> create_request(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_request(attrs \\ %{}) do
    %Request{}
    |> Request.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a request.

  ## Examples

      iex> update_request(request, %{field: new_value})
      {:ok, %Request{}}

      iex> update_request(request, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_request(%Request{} = request, attrs) do
    request
    |> Request.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a request.

  ## Examples

      iex> delete_request(request)
      {:ok, %Request{}}

      iex> delete_request(request)
      {:error, %Ecto.Changeset{}}

  """
  def delete_request(%Request{} = request) do
    Repo.delete(request)
  end

  @doc """
  Deletes all requests older than the specified number of days.

  Returns the number of deleted requests.

  ## Examples

      iex> delete_requests_older_than_days(2)
      {10, nil}

  """
  def delete_requests_older_than_days(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    from(r in Request, where: r.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking request changes.

  ## Examples

      iex> change_request(request)
      %Ecto.Changeset{data: %Request{}}

  """
  def change_request(%Request{} = request, attrs \\ %{}) do
    Request.changeset(request, attrs)
  end

  @doc """
  Search requests by path, method, and/or query parameters.

  ## Examples

      iex> search_requests(%{url_path: "/api/users"})
      [%Request{}, ...]

      iex> search_requests(%{method: "GET", url_path: "/api/users"})
      [%Request{}, ...]

      iex> search_requests(%{query_contains: "user_id"})
      [%Request{}, ...]

  """
  def search_requests(filters \\ %{}) do
    Request
    |> build_search_query(filters)
    |> order_by(desc: :id)
    |> Repo.all()
  end

  defp build_search_query(query, filters) do
    Enum.reduce(filters, query, fn
      {:url_path, path}, query when is_binary(path) ->
        from r in query, where: r.url_path == ^path

      {:per_page, per_page}, query when is_integer(per_page) ->
        from r in query, limit: ^per_page

      {:url_path_like, path_pattern}, query when is_binary(path_pattern) ->
        from r in query, where: like(r.url_path, ^path_pattern)

      {:method, method}, query when is_binary(method) ->
        from r in query, where: r.method == ^method

      {:query_contains, param_key}, query when is_binary(param_key) ->
        from r in query, where: like(r.url_query, ^"%#{param_key}%")

      {:content_type, content_type}, query when is_binary(content_type) ->
        from r in query, where: r.content_type == ^content_type

      _filter, query ->
        query
    end)
  end
end
