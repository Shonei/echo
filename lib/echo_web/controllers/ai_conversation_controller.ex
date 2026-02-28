defmodule EchoWeb.AIConversationController do
  use EchoWeb, :controller

  alias Echo.Agents.ConversationManager

  def create(conn, params) do
    opts =
      params
      |> Map.take([
        "system_prompt",
        "temperature",
        "max_output_tokens",
        "thinking_enabled",
        "thinking_budget",
        "tools"
      ])

    conversation_id = ConversationManager.start_conversation(opts)

    conn
    |> put_status(:created)
    |> json(%{id: conversation_id})
  end

  def delete(conn, %{"id" => id}) do
    ConversationManager.kill_conversation(id)

    conn
    |> send_resp(:no_content, "")
  end

  def message(conn, %{"id" => id} = params) do
    text = params["message"] || params["text"] || params["content"]

    if is_binary(text) and text != "" do
      case ConversationManager.message(id, text) do
        {:ok, parts} ->
          json(conn, %{parts: parts})

        {:error, :conversation_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation not found"})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: to_string(reason)})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing or invalid message text"})
    end
  end

  def content(conn, %{"id" => id} = params) do
    blocks = params["content_blocks"] || params["content"] || params["blocks"]

    if is_list(blocks) do
      case ConversationManager.content(id, blocks) do
        {:ok, parts} ->
          json(conn, %{parts: parts})

        {:error, :conversation_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation not found"})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: to_string(reason)})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing or invalid content blocks list"})
    end
  end
end
