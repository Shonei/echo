defmodule EchoWeb.ChatChannel do
  use EchoWeb, :channel

  alias Echo.Chat
  alias Echo.AIChatServer
  alias Echo.AIUserRegistry

  @impl true
  def join("chat:" <> room, payload, socket) do
    if authorized?(payload) do
      # Subscribe to the room's PubSub topic
      # PubSub.subscribe(Echo.PubSub, "chat:#{room}")

      # Get recent messages for the room
      messages = Chat.list_messages(room, 50)

      # Assign room to socket
      socket = assign(socket, :room, room)

      # Send recent messages to the newly joined user
      {:ok, %{messages: format_messages(messages)}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Channels can be used in a request/response fashion
  # by sending replies to requests from the client
  @impl true
  def handle_in("new_message", %{"content" => content} = payload, socket) do
    room = socket.assigns.room
    user_id = socket.assigns.user_id

    # Use username from payload if provided, otherwise extract from user_id
    username = Map.get(payload, "username") || extract_username(user_id)

    case Chat.create_message(%{
           content: content,
           room: room,
           user_id: user_id,
           username: username
         }) do
      {:ok, message} ->
        # Broadcast the message to all subscribers
        # Chat.broadcast_message(room, message)
        broadcast!(socket, "new_message", %{message: format_message(message)})

        # Check if the message mentions any AI users and process them
        mentioned_ai_users = AIUserRegistry.find_mentioned_ai_users(content)

        if length(mentioned_ai_users) > 0 do
          AIChatServer.process_ai_mentions(room, message)
        end

        {:reply, {:ok, %{message: format_message(message)}}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{errors: format_errors(changeset)}}, socket}
    end
  end

  # Handle other events
  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  # Handle broadcasted messages
  @impl true
  def handle_info({:new_message, message}, socket) do
    push(socket, "new_message", %{message: format_message(message)})
    {:noreply, socket}
  end

  def handle_info({:outside_message, message}, socket) do
    IO.puts("Received outside message: #{inspect(message)}")
    push(socket, "new_message", %{message: format_message(message)})
    {:noreply, socket}
  end

  # Add authorization logic here
  defp authorized?(_payload) do
    # For now, allow all connections
    # In a real app, you'd check authentication tokens, etc.
    true
  end

  defp extract_username(user_id) do
    case String.split(user_id, "_") do
      ["anonymous", id] -> "Guest #{id}"
      _ -> user_id
    end
  end

  defp format_message(message) do
    %{
      id: message.id,
      content: message.content,
      username: message.username,
      user_id: message.user_id,
      inserted_at: message.inserted_at
    }
  end

  defp format_messages(messages) do
    Enum.map(messages, &format_message/1)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
