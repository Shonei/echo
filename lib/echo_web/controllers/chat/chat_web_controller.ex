defmodule EchoWeb.ChatWebController do
  use EchoWeb, :controller

  alias Echo.ChatRooms
  alias Echo.ChatRooms.ChatRoom

  def index(conn, _params) do
    # Set a user session if not exists
    conn =
      if get_session(conn, :user_id) do
        conn
      else
        user_id = "user_#{:rand.uniform(1_000_000)}"
        put_session(conn, :user_id, user_id)
      end

    # Fetch all chat rooms from the database
    rooms = ChatRooms.list_chat_room()

    render(conn, :index, rooms: rooms)
  end

  def new(conn, _params) do
    # Set a user session if not exists
    conn =
      if get_session(conn, :user_id) do
        conn
      else
        user_id = "user_#{:rand.uniform(1_000_000)}"
        put_session(conn, :user_id, user_id)
      end

    changeset = ChatRooms.change_chat_room(%ChatRoom{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"chat_room" => chat_room_params}) do
    case ChatRooms.create_chat_room(chat_room_params) do
      {:ok, _chat_room} ->
        conn
        |> put_flash(:info, "Chat room created successfully.")
        |> redirect(to: ~p"/chat")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end

  def edit(conn, %{"id" => id}) do
    # Set a user session if not exists
    conn =
      if get_session(conn, :user_id) do
        conn
      else
        user_id = "user_#{:rand.uniform(1_000_000)}"
        put_session(conn, :user_id, user_id)
      end

    chat_room = ChatRooms.get_chat_room!(id)
    changeset = ChatRooms.change_chat_room(chat_room)
    render(conn, :edit, chat_room: chat_room, changeset: changeset)
  end

  def update(conn, %{"id" => id, "chat_room" => chat_room_params}) do
    chat_room = ChatRooms.get_chat_room!(id)

    case ChatRooms.update_chat_room(chat_room, chat_room_params) do
      {:ok, _chat_room} ->
        conn
        |> put_flash(:info, "Chat room updated successfully.")
        |> redirect(to: ~p"/chat")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, chat_room: chat_room, changeset: changeset)
    end
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
