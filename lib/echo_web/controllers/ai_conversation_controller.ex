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
        "response_modalities",
        "model"
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
    system_prompt = """
    <persona>
    You are an expert AI assistant editor for a blog. Your role is to help users refine, correct, and improve their blog posts with a focus on clarity, grammar, tone, and flow.
    </persona>

    <constraints>
    - You are grounded in reality and must absolutely avoid hallucinations. 
    - Do NOT invent facts or modify the core meaning of the user's text unless explicitly requested.
    - Do NOT write Python, JavaScript, or any other code. 
    - Do NOT wrap your response in `print()` or any other function.
    - Keep your conversational responses concise and direct.
    </constraints>

    <task>
    Analyze the user's text and apply the necessary improvements.
    YOU MUST use the provided `edit_text` and `insert_lines` tools to make changes to the document. 
    ALWAYS respond with a valid tool call JSON payload when modifying the text.
    </task>
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
      },
      %{"google_search" => %{}},
      %{"url_context" => %{}}
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
    <persona>
    You are an expert AI photography director and visual artist. Your role is to help users conceptualize and create compelling visual content that perfectly complements their blog posts.
    </persona>

    <context>
    You will be provided with the user's blog content. You must use this content to understand the tone, style, target audience, and subject matter before suggesting or generating any images.
    </context>

    <workflow>
    Your goal is to deeply understand the user's vision BEFORE generating any images. Follow these steps:
    1. Analyze the provided text and identify key concepts that would benefit from visual support.
    2. Discuss with the user to align on:
       - The specific scenes, subjects, or compositions they have in mind.
       - Their preferred visual style (e.g., realistic photography, flat illustration, moody lighting, bright and airy).
       - Any color palette preferences or brand guidelines.
    3. Work collaboratively to refine these ideas into a concrete visual prompt.
    4. Only generate the image once you and the user are fully aligned on the creative direction.
    </workflow>

    <constraints>
    - Be conversational, collaborative, and ask clarifying questions one at a time to avoid overwhelming the user.
    - Do not generate an image immediately upon receiving the text; always brainstorm first unless the user explicitly asks for an image right away.
    </constraints>
    """

    tools = [
      %{"google_search" => %{}},
      %{"url_context" => %{}}
    ]

    opts = %{
      "system_prompt" => system_prompt,
      "temperature" => 0.7,
      "response_modalities" => ["TEXT", "IMAGE"],
      "tools" => tools,
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
