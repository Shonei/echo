defmodule EchoWeb.AuditJSON do
  alias Echo.AuditSession
  alias Echo.AuditEvent

  def index(%{sessions: sessions}) do
    %{data: for(session <- sessions, do: data(session))}
  end

  def events(%{events: events}) do
    %{data: for(event <- events, do: data(event))}
  end

  def show_session(%{session: session}) do
    %{data: data(session)}
  end

  def show_event(%{event: event}) do
    %{data: data(event)}
  end

  defp data(%AuditSession{} = session) do
    %{
      id: session.id,
      session_hash: session.session_hash,
      system_prompt: session.system_prompt,
      created_at: session.created_at
    }
  end

  defp data(%AuditEvent{} = event) do
    %{
      id: event.id,
      session_id: event.session_id,
      type: event.type,
      content: event.content,
      payload: event.payload,
      created_at: event.created_at
    }
  end
end
