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
        "tools",
        "response_modalities"
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
        {:ok, parts} ->
          json(conn, %{parts: parts})

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
        {:ok, parts} ->
          json(conn, %{parts: parts})

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
    system_prompt = """
    You are an expert AI assistant editor for a blog. Your role is to help users refine, correct, and improve their blog posts. Focus on clarity, grammar, tone, and flow.
    You are grounded in reality and must avoid hallucinations. Do not invent facts or modify the core meaning of the user's text unless requested.
    You have tools called `edit_text` and `insert_lines`. YOU MUST CALL THESE TOOLS BY RESPONDING WITH A VALID TOOL CALL JSON PAYLOAD.
    DO NOT WRITE PYTHON, JAVASCRIPT, OR ANY OTHER CODE. DO NOT WRAP YOUR RESPONSE IN `print()` OR ANY OTHER FUNCTION.
    """

    tools = [
      %{
        "functionDeclarations" => [
          %{
            "name" => "edit_text",
            "description" =>
              "Applies one or more text replacements to the document. You MUST provide the arguments as a JSON object matching this schema.",
            "parameters" => %{
              "type" => "OBJECT",
              "properties" => %{
                "replacements" => %{
                  "type" => "ARRAY",
                  "description" => "A list of text replacements to perform.",
                  "items" => %{
                    "type" => "OBJECT",
                    "properties" => %{
                      "old_text" => %{
                        "type" => "STRING",
                        "description" =>
                          "The exact, case-sensitive text currently in the document that needs to be replaced."
                      },
                      "new_text" => %{
                        "type" => "STRING",
                        "description" => "The new text that will replace the old_text."
                      }
                    },
                    "required" => ["old_text", "new_text"]
                  }
                }
              },
              "required" => ["replacements"]
            }
          },
          %{
            "name" => "insert_lines",
            "description" => "Inserts a sequence of lines at a specific line number.",
            "parameters" => %{
              "type" => "OBJECT",
              "properties" => %{
                "line_number" => %{
                  "type" => "INTEGER",
                  "description" =>
                    "The 1-indexed line number where the new lines should be inserted."
                },
                "lines" => %{
                  "type" => "ARRAY",
                  "description" => "The lines of text to insert.",
                  "items" => %{
                    "type" => "STRING"
                  }
                }
              },
              "required" => ["line_number", "lines"]
            }
          }
        ]
      }
    ]

    opts = %{
      "system_prompt" => system_prompt,
      "temperature" => 0.1,
      "tools" => tools
    }

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

  def photographer(conn, _params) do
    system_prompt = """
    You are an AI photographer agent helping users create compelling visual content for their blog.

    You will be provided with the blog content. Use it to understand the tone, style, target audience, and subject matter before suggesting or generating any images.

    Your goal is to deeply understand the user's vision before generating any images. Discuss with the user:
    - Which parts of the blog need visual support
    - Preferred visual style (e.g., realistic, illustrative, moody, bright)
    - Any specific scenes, subjects, or compositions they have in mind
    - Color palette preferences or brand guidelines

    Work collaboratively to refine ideas. Only generate images once you have a clear, shared understanding of what's needed. When you do, briefly explain your creative choices — framing, lighting, mood — so the user can give meaningful feedback.
    """

    opts = %{
      "system_prompt" => system_prompt,
      "temperature" => 0.7,
      "response_modalities" => ["TEXT", "IMAGE"],
      "tools" => nil,
      "model" => "gemini-3-pro-image-preview"
    }

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
