defmodule EchoWeb.ChatController do
  use EchoWeb, :controller

  alias Echo.Chat

  action_fallback EchoWeb.FallbackController

  def index(conn, _params) do
    # Return available rooms (for now just a hardcoded list)
    rooms = ["general", "random", "tech"]
    json(conn, %{rooms: rooms})
  end

  def messages(conn, %{"room" => room} = params) do
    limit = Map.get(params, "limit", "50") |> String.to_integer()
    messages = Chat.list_messages(room, limit)

    formatted_messages =
      Enum.map(messages, fn message ->
        %{
          id: message.id,
          content: message.content,
          username: message.username,
          user_id: message.user_id,
          inserted_at: message.inserted_at
        }
      end)

    json(conn, %{messages: formatted_messages})
  end

  def create_message(conn, %{"room" => room, "message" => message_params}) do
    # Read user_id from message params, fallback to session, then generate random ID
    user_id =
      message_params["user_id"] ||
        get_session(conn, :user_id) ||
        "api_user_#{:rand.uniform(1_000_000)}"

    username = message_params["username"] || "API User"

    attrs =
      Map.merge(message_params, %{
        "room" => room,
        "user_id" => user_id,
        "username" => username
      })

    case Chat.create_message(attrs) do
      {:ok, message} ->
        # Broadcast the message to WebSocket subscribers
        Chat.broadcast_message(room, message)

        formatted_message = %{
          id: message.id,
          content: message.content,
          username: message.username,
          user_id: message.user_id,
          inserted_at: message.inserted_at
        }

        conn
        |> put_status(:created)
        |> json(%{message: formatted_message})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
