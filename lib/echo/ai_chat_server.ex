defmodule Echo.AIChatServer do
  @moduledoc """
  GenServer that handles AI chat interactions for individual AI users.

  This server processes messages that mention @{username} for AI users, fetches the last 5 messages
  from the chat history, sends them to the appropriate AI model for processing, and broadcasts
  the AI response back to the chat room.
  """

  use GenServer
  require Logger

  alias Echo.Chat
  alias Echo.AIUserRegistry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @doc """
  Process AI user mentions in a chat message.

  This will find all mentioned AI users, fetch the last 5 messages from the room,
  send them to each AI user's configured model, and broadcast the responses back to the room.
  """
  def process_ai_mentions(room, message) do
    GenServer.cast(__MODULE__, {:process_ai_mentions, room, message})
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:process_ai_mentions, room, message}, state) do
    Task.start(fn ->
      try do
        # Find all AI users mentioned in the message
        mentioned_ai_users = AIUserRegistry.find_mentioned_ai_users(message.content)

        if length(mentioned_ai_users) > 0 do
          # Get the last 5 messages from the room (including the current one)
          recent_messages = Chat.list_messages(room, 5)

          # Process each mentioned AI user
          Enum.each(mentioned_ai_users, fn ai_user ->
            process_single_ai_user(ai_user, room, recent_messages, message)
          end)
        end
      rescue
        exception ->
          Logger.error("Exception in AI mentions processing: #{inspect(exception)}")
      end
    end)

    {:noreply, state}
  end

  # Private functions

  defp process_single_ai_user(ai_user, room, recent_messages, _original_message) do
    try do
      # Generate AI response for this specific user
      case generate_ai_response_for_user(ai_user, recent_messages) do
        {:ok, ai_response} ->
          # Create AI message in the database using the AI user's username
          case Chat.create_message(%{
                 content: ai_response,
                 room: room,
                 user_id: ai_user.username,
                 username: ai_user.username
               }) do
            {:ok, ai_message} ->
              # Broadcast the AI response to the room
              Chat.broadcast_message(room, ai_message)
              Logger.info("AI response sent to room #{room} from #{ai_user.username}")

            {:error, reason} ->
              Logger.error(
                "Failed to create AI message for #{ai_user.username}: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Logger.error(
            "Failed to generate AI response for #{ai_user.username}: #{inspect(reason)}"
          )

          # Send error message to chat
          error_message =
            "Sorry, I'm having trouble responding right now. Please try again later."

          case Chat.create_message(%{
                 content: error_message,
                 room: room,
                 user_id: ai_user.username,
                 username: ai_user.username
               }) do
            {:ok, error_msg} ->
              Chat.broadcast_message(room, error_msg)

            {:error, _} ->
              Logger.error("Failed to send error message for #{ai_user.username}")
          end
      end
    rescue
      exception ->
        Logger.error("Exception in AI processing for #{ai_user.username}: #{inspect(exception)}")
    end
  end

  defp generate_ai_response_for_user(ai_user, recent_messages) do
    api_key = get_gemini_api_key()

    if is_nil(api_key) do
      {:error, "Gemini API key not configured"}
    else
      # Get AI user's configuration from the flat metadata structure
      prompt = Map.get(ai_user.metadata, "prompt", "You are a helpful assistant.")
      model = Map.get(ai_user.metadata, "model", "gemini-2.5-flash-lite")
      temperature = parse_number(Map.get(ai_user.metadata, "temperature", "0.7"))
      max_tokens = parse_number(Map.get(ai_user.metadata, "max_tokens", "1000"))

      # Format messages for Gemini
      chat_history = format_messages_for_gemini(recent_messages)

      payload = %{
        contents: [
          %{
            parts: [
              %{
                text: prompt <> "\n\nChat History:\n" <> chat_history
              }
            ]
          }
        ],
        generationConfig: %{
          temperature: temperature,
          maxOutputTokens: max_tokens
        }
      }

      # Make the API request
      headers = [
        {"Content-Type", "application/json"}
      ]

      # Build URL with the user's specific model
      base_url =
        "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent"

      url = base_url <> "?key=#{api_key}"
      body = Jason.encode!(payload)

      case HTTPoison.post(url, body, headers, timeout: 30_000) do
        {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}]}} | _]}} ->
              {:ok, String.trim(text)}

            {:ok, response} ->
              Logger.error("Unexpected Gemini response format: #{inspect(response)}")
              {:error, "Unexpected response format from AI service"}

            {:error, decode_error} ->
              Logger.error("Failed to decode Gemini response: #{inspect(decode_error)}")
              {:error, "Failed to parse AI response"}
          end

        {:ok, %HTTPoison.Response{status_code: status_code, body: error_body}} ->
          Logger.error("Gemini API error #{status_code}: #{error_body}")
          {:error, "AI service returned error: #{status_code}"}

        {:error, %HTTPoison.Error{reason: reason}} ->
          Logger.error("HTTP request failed: #{inspect(reason)}")
          {:error, "Failed to connect to AI service"}
      end
    end
  end

  defp format_messages_for_gemini(messages) do
    messages
    # Most recent first
    |> Enum.reverse()
    |> Enum.map(fn message ->
      timestamp = message.inserted_at |> DateTime.to_string()
      "[#{timestamp}] #{message.username}: #{message.content}"
    end)
    |> Enum.join("\n")
  end

  defp get_gemini_api_key do
    System.get_env("GEMINI_API_KEY") ||
      Application.get_env(:echo, :gemini_api_key)
  end

  defp parse_number(value) when is_number(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} ->
        num

      _ ->
        case Integer.parse(value) do
          {num, ""} -> num
          # Default fallback
          _ -> 0.7
        end
    end
  end

  # Default fallback
  defp parse_number(_), do: 0.7
end
