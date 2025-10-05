defmodule Echo.ChatRoomsTest do
  use Echo.DataCase

  alias Echo.ChatRooms

  describe "chat_room" do
    alias Echo.ChatRooms.ChatRoom

    import Echo.ChatRoomsFixtures

    @invalid_attrs %{name: nil, type: nil, description: nil, password: nil}

    test "list_chat_room/0 returns all chat_room" do
      chat_room = chat_room_fixture()
      assert ChatRooms.list_chat_room() == [chat_room]
    end

    test "get_chat_room!/1 returns the chat_room with given id" do
      chat_room = chat_room_fixture()
      assert ChatRooms.get_chat_room!(chat_room.id) == chat_room
    end

    test "create_chat_room/1 with valid data creates a chat_room" do
      valid_attrs = %{name: "some name", type: "some type", description: "some description", password: "some password"}

      assert {:ok, %ChatRoom{} = chat_room} = ChatRooms.create_chat_room(valid_attrs)
      assert chat_room.name == "some name"
      assert chat_room.type == "some type"
      assert chat_room.description == "some description"
      assert chat_room.password == "some password"
    end

    test "create_chat_room/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = ChatRooms.create_chat_room(@invalid_attrs)
    end

    test "update_chat_room/2 with valid data updates the chat_room" do
      chat_room = chat_room_fixture()
      update_attrs = %{name: "some updated name", type: "some updated type", description: "some updated description", password: "some updated password"}

      assert {:ok, %ChatRoom{} = chat_room} = ChatRooms.update_chat_room(chat_room, update_attrs)
      assert chat_room.name == "some updated name"
      assert chat_room.type == "some updated type"
      assert chat_room.description == "some updated description"
      assert chat_room.password == "some updated password"
    end

    test "update_chat_room/2 with invalid data returns error changeset" do
      chat_room = chat_room_fixture()
      assert {:error, %Ecto.Changeset{}} = ChatRooms.update_chat_room(chat_room, @invalid_attrs)
      assert chat_room == ChatRooms.get_chat_room!(chat_room.id)
    end

    test "delete_chat_room/1 deletes the chat_room" do
      chat_room = chat_room_fixture()
      assert {:ok, %ChatRoom{}} = ChatRooms.delete_chat_room(chat_room)
      assert_raise Ecto.NoResultsError, fn -> ChatRooms.get_chat_room!(chat_room.id) end
    end

    test "change_chat_room/1 returns a chat_room changeset" do
      chat_room = chat_room_fixture()
      assert %Ecto.Changeset{} = ChatRooms.change_chat_room(chat_room)
    end
  end
end
