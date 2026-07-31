defmodule Echo.AuditSessions do
  @moduledoc """
  The Requests context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.AuditSession

  def save_session(attrs \\ %{}) do
    %AuditSession{}
    |> AuditSession.changeset(attrs)
    |> Repo.insert()
  end

  def list_sessions(params \\ %{}) do
    page = Map.get(params, "page", 1)
    page_size = Map.get(params, "page_size", 10)

    # Enforce min 10, max 50
    page_size =
      case Integer.parse(to_string(page_size)) do
        {size, _} -> max(10, min(size, 50))
        :error -> 10
      end

    page =
      case Integer.parse(to_string(page)) do
        {p, _} -> max(1, p)
        :error -> 1
      end

    offset = (page - 1) * page_size

    query =
      from(s in AuditSession,
        # id breaks ties: created_at is second-precision and Postgres gives no
        # stable order within a second, which would make pages overlap.
        order_by: [desc: s.created_at, desc: s.id],
        limit: ^page_size,
        offset: ^offset
      )

    Repo.all(query)
  end
end
