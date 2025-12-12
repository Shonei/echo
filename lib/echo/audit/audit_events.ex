defmodule Echo.AuditEvents do
  @moduledoc """
  The Requests context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.AuditEvent

  def count_audit_events(filters \\ %{}) do
    with {:ok, query} <- build_search_query(AuditEvent, filters) do
      {:ok, Repo.aggregate(query, :count)}
    end
  end

  def create_audit_event(attrs \\ %{}) do
    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  def search_audit_events(filters \\ %{}) do
    with {:ok, query} <- build_search_query(AuditEvent, filters) do
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
