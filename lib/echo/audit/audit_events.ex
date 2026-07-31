defmodule Echo.AuditEvents do
  @moduledoc """
  The Requests context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.AuditEvent

  def save_event(attrs \\ %{}) do
    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  def list_events(session_id) do
    AuditEvent
    |> where([e], e.session_id == ^session_id)
    |> order_by([e], asc: e.created_at, asc: e.id)
    |> Repo.all()
  end
end
