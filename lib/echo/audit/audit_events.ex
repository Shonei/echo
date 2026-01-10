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

  def save_event(attrs \\ %{}) do
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

  defp build_search_query(query, %{session_id: id}) when not is_nil(id) do
    {:ok, from(r in query, where: r.session_id == ^id)}
  end

  defp build_search_query(_query, _filters) do
    {:error, :missing_session_id}
  end
end
