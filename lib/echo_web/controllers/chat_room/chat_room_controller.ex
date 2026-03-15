defmodule EchoWeb.ChatRoomController do
  use EchoWeb, :controller

  alias Echo.ChatRooms
  alias Echo.ChatRooms.ChatRoom

  action_fallback EchoWeb.FallbackController

  def show(conn, %{"id" => id}) do
    chat_room = ChatRooms.get_chat_room!(id)
    render(conn, :show, chat_room: chat_room)
  end

  def delete(conn, %{"id" => id}) do
    chat_room = ChatRooms.get_chat_room!(id)

    with {:ok, %ChatRoom{}} <- ChatRooms.delete_chat_room(chat_room) do
      send_resp(conn, :no_content, "")
    end
  end
end
