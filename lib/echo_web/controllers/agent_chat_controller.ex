defmodule EchoWeb.AgentChatController do
  use EchoWeb, :controller

  alias Echo.Agents.ConversationManager
  alias Echo.Agent, as: AgentDB

  @models [
    {"Gemini 3.1 Pro Preview", "gemini-3.1-pro-preview"},
    {"Gemini 3 Pro Image Preview", "gemini-3-pro-image-preview"},
    {"Gemini 2.5 Pro", "gemini-2.5-pro"},
    {"Gemini 2.5 Flash", "gemini-2.5-flash"}
  ]

  def new(conn, _params) do
    render(conn, :new, models: @models)
  end

  def create(conn, %{"agent" => agent_params}) do
    opts =
      %{
        "system_prompt" => presence(agent_params["system_prompt"]),
        "model" => presence(agent_params["model"]),
        "temperature" => parse_float(agent_params["temperature"]),
        "max_output_tokens" => parse_integer(agent_params["max_output_tokens"]),
        "thinking_enabled" => checked?(agent_params["thinking_enabled"]),
        "thinking_budget" => parse_integer(agent_params["thinking_budget"]),
        "response_modalities" => modalities(agent_params["response_modalities"]),
        "tools" => tools(agent_params["tools"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case ConversationManager.start_conversation(opts) do
      {:ok, conversation_id} ->
        conn
        |> put_flash(:info, "Agent initialized successfully.")
        |> redirect(to: ~p"/agent-chat/#{conversation_id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to start conversation: #{inspect(reason)}")
        |> render(:new, models: @models)
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
        {:ok, parts, metadata} ->
          json(conn, %{parts: Enum.map(parts, &render_markdown/1), metadata: metadata})

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

  # --- Param helpers ---

  defp render_markdown(%{"text" => text} = part) when is_binary(text) do
    Map.put(part, "html", Earmark.as_html!(text))
  end

  defp render_markdown(%{text: text} = part) when is_binary(text) do
    Map.put(part, :html, Earmark.as_html!(text))
  end

  defp render_markdown(part), do: part

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp checked?("true"), do: true
  defp checked?(true), do: true
  defp checked?(_), do: nil

  defp modalities(%{"text" => "true", "image" => "true"}), do: ["TEXT", "IMAGE"]
  defp modalities(%{"image" => "true"}), do: ["IMAGE"]
  defp modalities(%{"text" => "true"}), do: ["TEXT"]
  defp modalities(list) when is_list(list), do: Enum.map(list, &String.upcase/1)
  defp modalities(_), do: ["TEXT"]

  # Gemini's own tools are declared as empty objects; Echo's are function
  # declarations that `Echo.Agents.ConversationServer` executes itself.
  defp tools(params) when is_map(params) do
    builtins =
      ["google_search", "url_context"]
      |> Enum.filter(&checked?(params[&1]))
      |> Enum.map(&%{&1 => %{}})

    backends =
      Echo.Agents.Tools.names()
      |> Enum.filter(&checked?(params[&1]))
      |> Echo.Agents.Tools.tool_config()
      |> List.wrap()

    case builtins ++ backends do
      [] -> nil
      list -> list
    end
  end

  defp tools(_), do: nil
end
