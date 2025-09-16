defmodule EchoWeb.ChatWebController do
  use EchoWeb, :controller

  def index(conn, _params) do
    # Set a user session if not exists
    conn =
      if get_session(conn, :user_id) do
        conn
      else
        user_id = "user_#{:rand.uniform(1_000_000)}"
        put_session(conn, :user_id, user_id)
      end

    render(conn, :index)
  end

  def room(conn, %{"room" => room}) do
    # Set a user session if not exists
    conn =
      if get_session(conn, :user_id) do
        conn
      else
        user_id = "user_#{:rand.uniform(1_000_000)}"
        put_session(conn, :user_id, user_id)
      end

    user_id = get_session(conn, :user_id)
    render(conn, :room, room: room, user_id: user_id)
  end
end
