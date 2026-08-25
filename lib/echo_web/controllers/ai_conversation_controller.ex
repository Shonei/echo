defmodule EchoWeb.AIConversationController do
  use EchoWeb, :controller

  alias Echo.Agents.ConversationManager
  alias Echo.Agents.Presets

  def create(conn, params) do
    opts =
      params
      |> Map.take([
        "system_prompt",
        "temperature",
        "max_output_tokens",
        "thinking_enabled",
        "thinking_budget",
        "tools",
        "response_modalities",
        "model",
        "provider"
      ])

    case ConversationManager.start_conversation(opts) do
      {:ok, conversation_id} ->
        conn
        |> put_status(:created)
        |> json(%{id: conversation_id})

      {:error, reason} ->
        error_msg =
          if String.Chars.impl_for(reason), do: to_string(reason), else: inspect(reason)

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to start conversation", details: error_msg})
    end
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
        {:ok, parts, metadata} ->
          json(conn, %{parts: parts, metadata: metadata})

        {:error, :conversation_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation not found"})

        {:error, reason} ->
          error_msg =
            if String.Chars.impl_for(reason), do: to_string(reason), else: inspect(reason)

          conn
          |> put_status(:bad_request)
          |> json(%{error: error_msg})
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
        {:ok, parts, metadata} ->
          json(conn, %{parts: parts, metadata: metadata})

        {:error, :conversation_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation not found"})

        {:error, reason} ->
          error_msg =
            if String.Chars.impl_for(reason), do: to_string(reason), else: inspect(reason)

          conn
          |> put_status(:bad_request)
          |> json(%{error: error_msg})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing or invalid content blocks list"})
    end
  end

  def editor(conn, _params) do
    start_preset(conn, Presets.editor())
  end

  def photographer(conn, _params) do
    start_preset(conn, Presets.photographer())
  end

  defp start_preset(conn, opts) do
    case ConversationManager.start_conversation(opts) do
      {:ok, conversation_id} ->
        conn
        |> put_status(:created)
        |> json(%{id: conversation_id})

      {:error, reason} ->
        error_msg =
          if String.Chars.impl_for(reason), do: to_string(reason), else: inspect(reason)

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to start conversation", details: error_msg})
    end
  end
end
