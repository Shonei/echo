defmodule Echo.Agents.Providers.Gemini do
  @moduledoc """
  A plain client for the Gemini API. Holds no process and no state: every call
  reads config fresh and makes its own request on the caller's process, so
  concurrent callers (one `Echo.Agents.ConversationServer` per conversation)
  run in parallel instead of queueing behind a single shared process.

  Maps Echo's canonical parts (see `Echo.Agents.Provider`) to and from the
  Gemini REST API JSON shapes.
  """
  @behaviour Echo.Agents.Provider

  require Logger

  defstruct [:api_key, :http_client, :model, :log_debug_body]

  # --- Client API ---

  @doc """
  Calls the Gemini API generateContent endpoint and returns canonical parts.

  `model` should be a model name like "gemini-3.7-flash"
  `contents` should be a list of canonical turns:
    [%{"role" => "user", "parts" => [%{"text" => "..."}]}]
  """
  @impl true
  def generate_content(contents, opts \\ [], timeout \\ 300_000) do
    config = get_config()

    # `opts[:timeout]` is what is left of the caller's turn budget (see
    # `Echo.Agents.ConversationServer`'s `@turn_budget_ms`). Without it a call
    # would take a fresh 300s of its own, which is how a turn could outlive the
    # `GenServer.call` waiting on it.
    timeout = Keyword.get(opts, :timeout) || timeout

    if is_nil(config.api_key) || config.api_key == "" do
      Logger.warning("GEMINI_API_KEY is not set. API calls will fail.")
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model) || config.model

      url =
        "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent"

      headers = [
        {"Content-Type", "application/json"},
        {"x-goog-api-key", config.api_key}
      ]

      body = contents |> build_payload(opts) |> Jason.encode!()

      if config.log_debug_body do
        Logger.info("Gemini API Request Body", %{body: body, url: url, headers: headers})
      end

      req = config.http_client.build(:post, url, headers, body)

      case config.http_client.request(req, Echo.Finch,
             receive_timeout: timeout,
             pool_timeout: 15_000
           ) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, decoded} -> extract_parts(decoded)
            {:error, reason} -> {:error, {:json_decode_error, reason, resp_body}}
          end

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("Gemini API Error: [#{status}] #{resp_body}")
          {:error, {:api_error, status, resp_body}}

        {:error, exception} ->
          Logger.error("Gemini API Request Failed: #{inspect(exception)}")
          {:error, {:request_failed, exception}}
      end
    end
  end

  @doc """
  Calls the Gemini API to list available models.
  """
  def list_models(timeout \\ 300_000) do
    config = get_config()

    if is_nil(config.api_key) || config.api_key == "" do
      {:error, :missing_api_key}
    else
      url = "https://generativelanguage.googleapis.com/v1beta/models"

      headers = [
        {"x-goog-api-key", config.api_key}
      ]

      req = config.http_client.build(:get, url, headers)

      case config.http_client.request(req, Echo.Finch,
             receive_timeout: timeout,
             pool_timeout: 15_000
           ) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, reason} -> {:error, {:json_decode_error, reason, resp_body}}
          end

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("Gemini API Error: [#{status}] #{resp_body}")
          {:error, {:api_error, status, resp_body}}

        {:error, exception} ->
          Logger.error("Gemini API Request Failed: #{inspect(exception)}")
          {:error, {:request_failed, exception}}
      end
    end
  end

  # --- Configuration ---

  defp get_config do
    config = Application.get_env(:echo, __MODULE__, [])

    %__MODULE__{
      api_key: Keyword.get(config, :api_key),
      http_client: Keyword.get(config, :http_client, Finch),
      model: Keyword.get(config, :model),
      log_debug_body: Keyword.get(config, :log_debug_body, false)
    }
  end

  # --- Tool declarations ---

  @doc """
  Wraps canonical tool declarations as Gemini function declarations.

  Gemini's schema dialect spells JSON Schema types in upper case (`"OBJECT"`,
  not `"object"`), so the whole `parameters` tree is walked and rewritten.
  """
  @impl true
  def build_function_tools(declarations) when is_list(declarations) do
    %{"functionDeclarations" => Enum.map(declarations, &upcase_parameters/1)}
  end

  defp upcase_parameters(%{"parameters" => parameters} = declaration) do
    Map.put(declaration, "parameters", upcase_types(parameters))
  end

  defp upcase_parameters(declaration), do: declaration

  defp upcase_types(%{} = schema) do
    Map.new(schema, fn
      {"type", value} when is_binary(value) -> {"type", String.upcase(value)}
      {key, value} -> {key, upcase_types(value)}
    end)
  end

  defp upcase_types(list) when is_list(list), do: Enum.map(list, &upcase_types/1)
  defp upcase_types(other), do: other

  # --- Response parsing ---

  defp extract_parts(%{
         "candidates" => [%{"content" => %{"parts" => parts}} = candidate | _]
       }) do
    grounding = Map.get(candidate, "groundingMetadata")

    url_context =
      Map.get(candidate, "urlContextMetadata") || Map.get(candidate, "url_context_metadata")

    metadata = %{}
    metadata = if grounding, do: Map.put(metadata, "groundingMetadata", grounding), else: metadata

    metadata =
      if url_context, do: Map.put(metadata, "urlContextMetadata", url_context), else: metadata

    {:ok, %{parts: parts, metadata: metadata}}
  end

  defp extract_parts(%{
         "candidates" => [%{"finishReason" => reason, "finishMessage" => message} | _]
       }) do
    Logger.error("Gemini API returned finish reason: #{reason} with message: #{message}")
    {:error, {:gemini_error, reason, message}}
  end

  defp extract_parts(%{
         "candidates" => [%{"finishReason" => reason} | _]
       }) do
    Logger.error("Gemini API returned finish reason: #{reason}")
    {:error, {:gemini_error, reason}}
  end

  defp extract_parts(response) do
    Logger.error("Failed to extract parts from Gemini response: #{inspect(response)}")
    {:error, :unexpected_response_format}
  end

  # --- Payload construction ---

  @doc """
  Builds the `generateContent` request body. Public so the payload can be
  asserted on without going near the network.
  """
  def build_payload(contents, opts) do
    %{contents: format_contents(contents)}
    |> append_options(opts)
  end

  # --- Internal Helpers ---

  # Formats the contents to ensure they match Gemini's expected JSON format
  defp format_contents(contents) when is_list(contents) do
    Enum.map(contents, &format_content/1)
  end

  defp format_content(%{"role" => role, "parts" => parts}) do
    %{
      "role" => role,
      "parts" => Enum.map(parts, &format_part/1)
    }
  end

  # Default role is generic if not specified (sometimes just providing parts is enough)
  defp format_content(%{"parts" => parts}) do
    %{
      "parts" => Enum.map(parts, &format_part/1)
    }
  end

  # Only support text, functionCall, functionResponse, inlineData for now
  defp format_part(%{"text" => _} = part), do: part

  # Canonical parts can carry keys another provider needs and Gemini rejects:
  # OpenRouter pairs a call with its response by an `"id"` that has no place in
  # a Gemini request. Take only the keys Gemini's own schema defines.
  defp format_part(%{"functionCall" => call} = part) do
    part
    |> Map.take(["functionCall", "thought", "thoughtSignature"])
    |> Map.put("functionCall", Map.take(call, ["name", "args"]))
  end

  defp format_part(%{"functionResponse" => resp}),
    do: %{"functionResponse" => Map.take(resp, ["name", "response"])}

  defp format_part(%{"toolCall" => _} = part), do: part
  defp format_part(%{"toolResponse" => _} = part), do: part
  defp format_part(%{"inlineData" => %{"mimeType" => _, "data" => _}} = part), do: part
  defp format_part(%{"thought" => _} = part), do: part

  defp format_part(part) when is_map(part) do
    # Pass through other parts if they match schemas exactly, but warn
    Logger.warning("Unknown part type passed to Gemini API: #{inspect(Map.keys(part))}")
    part
  end

  defp append_options(payload, opts) do
    payload
    |> maybe_add_system_prompt(opts[:system_prompt])
    |> maybe_add_tools(opts[:tools])
    |> maybe_add_generation_config(opts)
  end

  defp maybe_add_tools(payload, nil), do: payload

  # An empty list is not the same as no tools: sending "tools": [] to a model
  # that cannot use tools at all (the image models) makes Gemini fail.
  defp maybe_add_tools(payload, []), do: payload

  defp maybe_add_tools(payload, tools) when is_list(tools) do
    payload = Map.put(payload, :tools, tools)

    # Gemini rejects built-in tools declared alongside function calling unless
    # this is set: "Please enable tool_config.include_server_side_tool_invocations
    # to use Built-in tools with Function calling."
    if mixes_builtins_and_functions?(tools) do
      Map.put(payload, :toolConfig, %{includeServerSideToolInvocations: true})
    else
      payload
    end
  end

  defp maybe_add_tools(payload, _), do: payload

  @builtin_tools ~w(google_search url_context google_search_retrieval code_execution
                    file_search google_maps computer_use)

  defp mixes_builtins_and_functions?(tools) do
    has_functions? = Enum.any?(tools, &Map.has_key?(&1, "functionDeclarations"))

    has_builtin? =
      Enum.any?(tools, fn tool ->
        is_map(tool) and Enum.any?(@builtin_tools, &Map.has_key?(tool, &1))
      end)

    has_functions? and has_builtin?
  end

  defp maybe_add_system_prompt(payload, nil), do: payload

  defp maybe_add_system_prompt(payload, prompt) do
    Map.put(payload, :systemInstruction, %{parts: [%{text: prompt}]})
  end

  defp maybe_add_generation_config(payload, opts) do
    config =
      %{}
      |> maybe_put(:temperature, opts[:temperature])
      |> maybe_put(:maxOutputTokens, opts[:max_output_tokens])
      |> maybe_put(:responseModalities, opts[:response_modalities])

    config =
      if opts[:thinking_enabled] do
        thinking_config = %{} |> maybe_put(:thinkingBudget, opts[:thinking_budget])
        Map.put(config, :thinkingConfig, thinking_config)
      else
        config
      end

    if map_size(config) > 0 do
      Map.put(payload, :generationConfig, config)
    else
      payload
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
