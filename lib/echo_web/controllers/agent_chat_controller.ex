defmodule EchoWeb.AgentChatController do
  use EchoWeb, :controller

  alias Echo.Agents.ConversationManager
  alias Echo.Agent, as: AgentDB

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"agent" => agent_params}) do
    modalities =
      case agent_params["response_modalities"] do
        %{"text" => "true", "image" => "true"} -> ["TEXT", "IMAGE"]
        %{"text" => "true"} -> ["TEXT"]
        %{"image" => "true"} -> ["IMAGE"]
        list when is_list(list) -> Enum.map(list, &String.upcase/1)
        _ -> ["TEXT"]
      end

    temperature =
      case Float.parse(agent_params["temperature"] || "0.7") do
        {val, _} -> val
        :error -> 0.7
      end

    opts = %{
      "system_prompt" => agent_params["system_prompt"],
      "model" => agent_params["model"],
      "temperature" => temperature,
      "response_modalities" => modalities
    }

    case ConversationManager.start_conversation(opts) do
      {:ok, conversation_id} ->
        conn
        |> put_flash(:info, "Agent initialized successfully.")
        |> redirect(to: ~p"/agent-chat/#{conversation_id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to start conversation: #{inspect(reason)}")
        |> render(:new)
    end
  end

  def show(conn, %{"id" => id}) do
    messages = AgentDB.list_messages_by_session(id)
    render(conn, :show, session_id: id, messages: messages)
  end

  def content(conn, %{"id" => id} = params) do
    blocks = params["content_blocks"] || params["content"] || params["blocks"]

    if is_list(blocks) do
      case ConversationManager.content(id, blocks) do
        {:ok, parts} ->
          parts_with_html = Enum.map(parts, fn
            %{"text" => text} = part -> Map.put(part, "html", Earmark.as_html!(text))
            %{text: text} = part -> Map.put(part, :html, Earmark.as_html!(text))
            part -> part
          end)
          json(conn, %{parts: parts_with_html})

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
end
