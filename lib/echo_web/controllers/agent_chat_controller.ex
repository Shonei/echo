defmodule EchoWeb.AgentChatController do
  use EchoWeb, :controller

  require Logger

  alias Echo.Agents.ConversationManager
  alias Echo.Agent, as: AgentDB

  @models [
    {"Gemini 3.1 Pro Preview", "gemini-3.1-pro-preview"},
    {"Gemini 3.7 Flash", "gemini-3.7-flash"},
    {"Gemini 3 Pro Image Preview", "gemini-3-pro-image-preview"},
    {"Gemini 2.5 Pro", "gemini-2.5-pro"},
    {"Gemini 2.5 Flash", "gemini-2.5-flash"}
  ]

  @providers [
    {"Gemini", "gemini"},
    {"OpenRouter", "openrouter"}
  ]

  def new(conn, _params) do
    render_form(conn)
  end

  def create(conn, %{"agent" => agent_params}) do
    provider = presence(agent_params["provider"]) || "gemini"

    with {:ok, provider_module} <- Echo.Agents.Providers.resolve(provider),
         {:ok, raw_tools} <- parse_raw_tools(agent_params["openrouter_tools"]),
         {:ok, model} <- model(agent_params, provider),
         opts = build_opts(agent_params, provider, provider_module, model, raw_tools),
         {:ok, conversation_id} <- ConversationManager.start_conversation(opts) do
      conn
      |> put_flash(:info, "Agent initialized successfully.")
      |> redirect(to: ~p"/agent-chat/#{conversation_id}")
    else
      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to start conversation: #{describe(reason)}")
        |> render_form()
    end
  end

  defp render_form(conn) do
    render(
      conn,
      :new,
      models: @models,
      providers: @providers,
      openrouter_models: openrouter_models()
    )
  end

  # Fetched live rather than hardcoded: OpenRouter fronts hundreds of models and
  # the list turns over constantly. If the call fails the form still works --
  # the slug field below the select takes anything.
  defp openrouter_models do
    case Echo.Agents.Providers.OpenRouter.list_models(5_000) do
      {:ok, models} ->
        models

      {:error, reason} ->
        Logger.warning("Could not list OpenRouter models for the agent form: #{inspect(reason)}")
        []
    end
  end

  # A typed slug wins over the select, so a model too new to be listed is still
  # reachable. Caught here rather than at the first message: OpenRouter has no
  # default model, and finding that out only after typing a message is a
  # miserable way to learn it.
  defp model(params, "openrouter") do
    case presence(params["openrouter_model_custom"]) || presence(params["openrouter_model"]) do
      nil -> {:error, :missing_model}
      model -> {:ok, model}
    end
  end

  defp model(params, _provider), do: {:ok, presence(params["model"])}

  defp build_opts(params, provider, provider_module, model, raw_tools) do
    %{
      "provider" => provider,
      "system_prompt" => presence(params["system_prompt"]),
      "model" => model,
      "temperature" => parse_float(params["temperature"]),
      "max_output_tokens" => parse_integer(params["max_output_tokens"]),
      "thinking_enabled" => thinking_enabled(params, provider),
      "thinking_budget" => thinking_budget(params, provider),
      "response_modalities" => modalities(params["response_modalities"], provider),
      "tools" => tools(params, provider, provider_module, raw_tools)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Thinking and image output are Gemini-only today; the OpenRouter provider
  # would only log that it ignored them, so don't send them in the first place.
  defp thinking_enabled(_params, "openrouter"), do: nil
  defp thinking_enabled(params, _provider), do: checked?(params["thinking_enabled"])

  defp thinking_budget(_params, "openrouter"), do: nil
  defp thinking_budget(params, _provider), do: parse_integer(params["thinking_budget"])

  defp describe(:missing_model), do: "OpenRouter needs a model — pick one or type a slug."
  defp describe({:unknown_provider, name}), do: "unknown provider #{inspect(name)}"
  defp describe({:invalid_tools_json, message}), do: "tools JSON is invalid: #{message}"
  defp describe(reason), do: inspect(reason)

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

  defp modalities(_params, "openrouter"), do: nil
  defp modalities(params, _provider), do: modalities(params)

  defp modalities(%{"text" => "true", "image" => "true"}), do: ["TEXT", "IMAGE"]
  defp modalities(%{"image" => "true"}), do: ["IMAGE"]
  defp modalities(%{"text" => "true"}), do: ["TEXT"]
  defp modalities(list) when is_list(list), do: Enum.map(list, &String.upcase/1)
  defp modalities(_), do: ["TEXT"]

  # OpenRouter resolves these two itself, inside a single response: the model
  # searches or fetches without a client round-trip, and the results come back
  # as `annotations` on the reply rather than as tool calls Echo runs. That's
  # why they're built here as declarations and never touch `Echo.Agents.Tools`.
  defp tools(params, "openrouter", provider_module, raw_tools) do
    tool_params = params["tools"] || %{}

    server_tools =
      [
        web_search_tool(tool_params, params),
        web_fetch_tool(tool_params, params)
      ]
      |> Enum.reject(&is_nil/1)

    case server_tools ++ raw_tools ++ backend_tools(tool_params, provider_module) do
      [] -> nil
      list -> list
    end
  end

  # Gemini's own tools are declared as empty objects; Echo's are function
  # declarations that `Echo.Agents.ConversationServer` executes itself.
  defp tools(params, _provider, provider_module, _raw_tools) do
    tool_params = params["tools"]

    builtins =
      if is_map(tool_params) do
        ["google_search", "url_context"]
        |> Enum.filter(&checked?(tool_params[&1]))
        |> Enum.map(&%{&1 => %{}})
      else
        []
      end

    case builtins ++ backend_tools(tool_params, provider_module) do
      [] -> nil
      list -> list
    end
  end

  defp backend_tools(tool_params, provider_module) when is_map(tool_params) do
    Echo.Agents.Tools.names()
    |> Enum.filter(&checked?(tool_params[&1]))
    |> Echo.Agents.Tools.declarations(provider_module)
    |> List.wrap()
  end

  defp backend_tools(_tool_params, _provider_module), do: []

  defp web_search_tool(tool_params, params) do
    if checked?(tool_params["web_search"]) do
      parameters =
        %{}
        |> maybe_put("engine", engine(params["web_search_engine"]))
        |> maybe_put("max_results", parse_integer(params["web_search_max_results"]))

      server_tool("openrouter:web_search", parameters)
    end
  end

  defp web_fetch_tool(tool_params, params) do
    if checked?(tool_params["web_fetch"]) do
      parameters =
        %{}
        |> maybe_put("engine", engine(params["web_fetch_engine"]))
        |> maybe_put("max_content_tokens", parse_integer(params["web_fetch_max_content_tokens"]))

      server_tool("openrouter:web_fetch", parameters)
    end
  end

  # "auto" is OpenRouter's own default, so leave it out rather than pinning it.
  defp engine("auto"), do: nil
  defp engine(value), do: presence(value)

  defp server_tool(type, parameters) when map_size(parameters) == 0, do: %{"type" => type}
  defp server_tool(type, parameters), do: %{"type" => type, "parameters" => parameters}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_raw_tools(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, []}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, list} when is_list(list) -> {:ok, list}
          {:ok, map} when is_map(map) -> {:ok, [map]}
          {:ok, _} -> {:error, {:invalid_tools_json, "expected an object or an array of objects"}}
          {:error, error} -> {:error, {:invalid_tools_json, Exception.message(error)}}
        end
    end
  end

  defp parse_raw_tools(_value), do: {:ok, []}
end
