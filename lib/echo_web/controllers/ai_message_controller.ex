defmodule EchoWeb.AIMessageController do
  use EchoWeb, :controller

  alias Echo.Agent

  def index(conn, _params) do
    conversations = Agent.list_conversations()
    render(conn, :index, conversations: conversations)
  end

  def show(conn, %{"id" => session_id}) do
    messages = Agent.list_messages_by_session(session_id)
    resumable = not is_nil(Agent.get_conversation(session_id))
    render(conn, :show, session_id: session_id, messages: messages, resumable: resumable)
  end
end
