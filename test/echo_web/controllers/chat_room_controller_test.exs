defmodule EchoWeb.ChatRoomControllerTest do
  use EchoWeb.ConnCase

  import Echo.ChatRoomsFixtures

  alias Echo.ChatRooms.ChatRoom

  @create_attrs %{
    name: "some name",
    type: "some type",
    description: "some description",
    password: "some password"
  }
  @update_attrs %{
    name: "some updated name",
    type: "some updated type",
    description: "some updated description",
    password: "some updated password"
  }
  @invalid_attrs %{name: nil, type: nil, description: nil, password: nil}

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all chat_room", %{conn: conn} do
      conn = get(conn, ~p"/api/chat_room")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create chat_room" do
    test "renders chat_room when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/chat_room", chat_room: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/chat_room/#{id}")

      assert %{
               "id" => ^id,
               "description" => "some description",
               "name" => "some name",
               "password" => "some password",
               "type" => "some type"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/chat_room", chat_room: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update chat_room" do
    setup [:create_chat_room]

    test "renders chat_room when data is valid", %{conn: conn, chat_room: %ChatRoom{id: id} = chat_room} do
      conn = put(conn, ~p"/api/chat_room/#{chat_room}", chat_room: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/chat_room/#{id}")

      assert %{
               "id" => ^id,
               "description" => "some updated description",
               "name" => "some updated name",
               "password" => "some updated password",
               "type" => "some updated type"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, chat_room: chat_room} do
      conn = put(conn, ~p"/api/chat_room/#{chat_room}", chat_room: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete chat_room" do
    setup [:create_chat_room]

    test "deletes chosen chat_room", %{conn: conn, chat_room: chat_room} do
      conn = delete(conn, ~p"/api/chat_room/#{chat_room}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/api/chat_room/#{chat_room}")
      end
    end
  end

  defp create_chat_room(_) do
    chat_room = chat_room_fixture()
    %{chat_room: chat_room}
  end
end
