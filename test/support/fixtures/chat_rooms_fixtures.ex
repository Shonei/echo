defmodule Echo.ChatRoomsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Echo.ChatRooms` context.
  """

  @doc """
  Generate a chat_room.
  """
  def chat_room_fixture(attrs \\ %{}) do
    {:ok, chat_room} =
      attrs
      |> Enum.into(%{
        description: "some description",
        name: "some name",
        password: "some password",
        type: "some type"
      })
      |> Echo.ChatRooms.create_chat_room()

    chat_room
  end
end
