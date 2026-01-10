defmodule Echo.AuditSessions do
  @moduledoc """
  The Requests context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.AuditSession

  def count_audit_events(filters \\ %{}) do
    with {:ok, query} <- build_search_query(AuditSession, filters) do
      {:ok, Repo.aggregate(query, :count)}
    end
  end

  def save_session(attrs \\ %{}) do
    %AuditSession{}
    |> AuditSession.changeset(attrs)
    |> Repo.insert()
  end

  def search_audit_events(filters \\ %{}) do
    with {:ok, query} <- build_search_query(AuditSession, filters) do
      results =
        query
        |> order_by(desc: :created_at)
        |> Repo.all()

      {:ok, results}
    end
  end

  defp build_search_query(query, %{session_hash: hash}) when not is_nil(hash) do
    {:ok, from(r in query, where: r.session_hash == ^hash)}
  end

  defp build_search_query(_query, _filters) do
    {:error, :missing_session_hash}
  end
end
