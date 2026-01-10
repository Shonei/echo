defmodule EchoWeb.AuditController do
  use EchoWeb, :controller

  alias Echo.AuditSessions
  alias Echo.AuditEvents
  alias Echo.AuditSession
  alias Echo.AuditEvent

  action_fallback EchoWeb.FallbackController

  def create_session(conn, params) do
    with {:ok, %AuditSession{} = session} <- AuditSessions.save_session(params) do
      conn
      |> put_status(:created)
      |> render(:show_session, session: session)
    end
  end

  def create_event(conn, params) do
    with {:ok, %AuditEvent{} = event} <- AuditEvents.save_event(params) do
      conn
      |> put_status(:created)
      |> render(:show_event, event: event)
    end
  end
end
