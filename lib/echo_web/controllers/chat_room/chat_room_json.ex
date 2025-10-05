defmodule EchoWeb.ChatRoomJSON do
  alias Echo.ChatRooms.ChatRoom

  @doc """
  Renders a list of chat_room.
  """
  def index(%{chat_room: chat_room}) do
    %{data: for(chat_room <- chat_room, do: data(chat_room))}
  end

  @doc """
  Renders a single chat_room.
  """
  def show(%{chat_room: chat_room}) do
    %{data: data(chat_room)}
  end

  defp data(%ChatRoom{} = chat_room) do
    %{
      id: chat_room.id,
      name: chat_room.name,
      description: chat_room.description,
      type: chat_room.type,
      password: chat_room.password
    }
  end
end
