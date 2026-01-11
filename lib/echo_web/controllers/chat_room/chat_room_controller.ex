defmodule EchoWeb.ChatRoomController do
  use EchoWeb, :controller

  alias Echo.ChatRooms
  alias Echo.ChatRooms.ChatRoom

  action_fallback EchoWeb.FallbackController

  def index(conn, _params) do
    chat_room = ChatRooms.list_chat_room()
    render(conn, :index, chat_room: chat_room)
  end

  def show(conn, %{"id" => id}) do
    chat_room = ChatRooms.get_chat_room!(id)
    render(conn, :show, chat_room: chat_room)
  end

  def update(conn, %{"id" => id, "chat_room" => chat_room_params}) do
    chat_room = ChatRooms.get_chat_room!(id)

    with {:ok, %ChatRoom{} = chat_room} <- ChatRooms.update_chat_room(chat_room, chat_room_params) do
      render(conn, :show, chat_room: chat_room)
    end
  end

  def delete(conn, %{"id" => id}) do
    chat_room = ChatRooms.get_chat_room!(id)

    with {:ok, %ChatRoom{}} <- ChatRooms.delete_chat_room(chat_room) do
      send_resp(conn, :no_content, "")
    end
  end
end
