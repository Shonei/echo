defmodule Echo.Agents.Providers.OpenRouter do
  @moduledoc """
  A plain client for OpenRouter's chat-completions API, in the same shape as
  `Echo.Agents.Providers.Gemini`: no process, config read fresh per call.

  Translates Echo's canonical parts (see `Echo.Agents.Provider`) to and from
  the OpenAI-style wire format OpenRouter speaks. Two differences from Gemini
  drive most of the mapping:

    * A tool call and its result are paired by an `"id"`, not by name, so the
      id rides along on the canonical `functionCall`/`functionResponse` parts
      and is persisted with them.
    * Tool-call arguments are a JSON **string**, where Gemini's `args` is a map.

  OpenRouter's own server-side tools (`openrouter:web_search`,
  `openrouter:web_fetch`) resolve inside a single response with no client
  round-trip, and their results come back as `annotations` on the message.
  Those are captured into `metadata` verbatim so they land in `ai_messages`
  the same way Gemini's `groundingMetadata` already does.

  This pass is text and function calling only: no image input or output, and
  no `thinking_enabled` mapping.
  """
  @behaviour Echo.Agents.Provider

  require Logger

  defstruct [:api_key, :http_client, :log_debug_body]

  @url "https://openrouter.ai/api/v1/chat/completions"
  @models_url "https://openrouter.ai/api/v1/models"

  # Finish reasons that mean "the model stopped normally". Anything else, with
  # nothing extracted, is an error rather than an empty reply.
  @clean_finishes [nil, "stop", "tool_calls", "end_turn"]

  # --- Client API ---

  @doc """
  Calls OpenRouter's chat-completions endpoint and returns canonical parts.

  Unlike Gemini there is no configured default model — OpenRouter fronts
  hundreds of them and guessing one would be worse than failing, so
  `opts[:model]` is required (e.g. `"openai/gpt-5.6-luna"`).
  """
  @impl true
  def generate_content(messages, opts \\ [], timeout \\ 300_000) do
    config = get_config()
    model = Keyword.get(opts, :model)

    # See the note in `Echo.Agents.Providers.Gemini.generate_content/3`: this is
    # what remains of the caller's turn budget, not a fresh per-call timeout.
    timeout = Keyword.get(opts, :timeout) || timeout

    cond do
      is_nil(config.api_key) || config.api_key == "" ->
        Logger.warning("OPENROUTER_KEY is not set. API calls will fail.")
        {:error, :missing_api_key}

      is_nil(model) || model == "" ->
        Logger.error("No model set for an OpenRouter conversation; OpenRouter has no default.")
        {:error, :missing_model}

      true ->
        warn_unsupported(opts)
        request(config, messages, opts, timeout)
    end
  end

  defp request(config, messages, opts, timeout) do
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{config.api_key}"}
    ]

    body = messages |> build_payload(opts) |> Jason.encode!()

    if config.log_debug_body do
      Logger.info("OpenRouter API Request Body", %{body: body, url: @url})
    end

    req = config.http_client.build(:post, @url, headers, body)

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
        Logger.error("OpenRouter API Error: [#{status}] #{resp_body}")
        {:error, {:api_error, status, resp_body}}

      {:error, exception} ->
        Logger.error("OpenRouter API Request Failed: #{inspect(exception)}")
        {:error, {:request_failed, exception}}
    end
  end

  @doc """
  Lists the models OpenRouter currently fronts.

  The endpoint is public, so this works without a key. It's what lets the dev
  UI offer a real model list instead of a hardcoded one that goes stale —
  OpenRouter fronts hundreds and they turn over constantly.

  Returns `{:ok, [%{id:, name:, tools?:}]}` sorted by name, where `tools?`
  says whether the model can call tools at all.
  """
  def list_models(timeout \\ 15_000) do
    config = get_config()

    headers =
      if config.api_key && config.api_key != "" do
        [{"Authorization", "Bearer #{config.api_key}"}]
      else
        []
      end

    req = config.http_client.build(:get, @models_url, headers)

    case config.http_client.request(req, Echo.Finch,
           receive_timeout: timeout,
           pool_timeout: 5_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"data" => data}} when is_list(data) -> {:ok, parse_models(data)}
          {:ok, other} -> {:error, {:unexpected_response_format, other}}
          {:error, reason} -> {:error, {:json_decode_error, reason, body}}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenRouter models API Error: [#{status}] #{body}")
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        Logger.error("OpenRouter models request failed: #{inspect(exception)}")
        {:error, {:request_failed, exception}}
    end
  end

  defp parse_models(data) do
    data
    |> Enum.flat_map(fn
      %{"id" => id} = model when is_binary(id) ->
        [
          %{
            id: id,
            name: model["name"] || id,
            tools?: "tools" in (model["supported_parameters"] || [])
          }
        ]

      _ ->
        []
    end)
    |> Enum.sort_by(& &1.name)
  end

  # Settings this provider knowingly doesn't map yet. Logged rather than
  # silently dropped, so a caller that sets one can tell why nothing happened.
  defp warn_unsupported(opts) do
    if opts[:thinking_enabled] do
      Logger.warning("thinking_enabled is not mapped for OpenRouter conversations; ignoring it.")
    end

    case opts[:response_modalities] do
      nil ->
        :ok

      ["TEXT"] ->
        :ok

      other ->
        Logger.warning("OpenRouter conversations are text-only; ignoring #{inspect(other)}")
    end
  end

  # --- Configuration ---

  defp get_config do
    config = Application.get_env(:echo, __MODULE__, [])

    %__MODULE__{
      api_key: Keyword.get(config, :api_key),
      http_client: Keyword.get(config, :http_client, Finch),
      log_debug_body: Keyword.get(config, :log_debug_body, false)
    }
  end

  # --- Tool declarations ---

  @doc """
  Wraps canonical tool declarations as OpenRouter function tools: a flat list,
  standard lowercase JSON Schema types kept as-is.
  """
  @impl true
  def build_function_tools(declarations) when is_list(declarations) do
    Enum.map(declarations, fn declaration ->
      function =
        %{"name" => declaration["name"]}
        |> maybe_put("description", declaration["description"])
        |> maybe_put("parameters", declaration["parameters"])

      %{"type" => "function", "function" => function}
    end)
  end

  # --- Payload construction ---

  @doc """
  Builds the chat-completions request body. Public so the payload can be
  asserted on without going near the network.
  """
  def build_payload(messages, opts) do
    %{
      "model" => opts[:model],
      "messages" => build_messages(messages, opts[:system_prompt])
    }
    |> maybe_put("tools", presence(opts[:tools]))
    |> maybe_put("temperature", opts[:temperature])
    |> maybe_put("max_tokens", opts[:max_output_tokens])
  end

  defp build_messages(turns, system_prompt) when is_list(turns) do
    system =
      if system_prompt, do: [%{"role" => "system", "content" => system_prompt}], else: []

    system ++ Enum.flat_map(turns, &turn_to_messages/1)
  end

  # A canonical turn can hold both tool results and ordinary content, but
  # OpenRouter wants every tool result as its own `role: "tool"` message, so
  # they're split out rather than merged into the turn's message.
  defp turn_to_messages(%{"role" => role, "parts" => parts} = turn) when is_list(parts) do
    {tool_parts, content_parts} =
      Enum.split_with(parts, &match?(%{"functionResponse" => _}, &1))

    Enum.map(tool_parts, &tool_message/1) ++
      content_message(role, content_parts, Map.get(turn, "metadata", %{}))
  end

  defp turn_to_messages(_), do: []

  defp tool_message(%{"functionResponse" => resp}) do
    %{
      "role" => "tool",
      # Falls back to the name for a response Echo didn't pair itself — a
      # client posting to /content need not know about ids. Better than a nil
      # `tool_call_id`, which OpenRouter rejects outright.
      "tool_call_id" => resp["id"] || resp["name"],
      "content" => encode_tool_result(resp["response"])
    }
  end

  defp content_message(_role, [], _metadata), do: []

  defp content_message(role, parts, metadata) do
    text =
      parts
      |> Enum.filter(&match?(%{"text" => _}, &1))
      |> Enum.map_join("\n", & &1["text"])

    tool_calls =
      parts
      |> Enum.filter(&match?(%{"functionCall" => _}, &1))
      |> Enum.map(&to_tool_call/1)

    wire_role = wire_role(role)

    message =
      %{"role" => wire_role, "content" => content_or_nil(text, tool_calls)}
      |> maybe_add_reasoning(wire_role, metadata)

    case tool_calls do
      [] -> [message]
      calls -> [Map.put(message, "tool_calls", calls)]
    end
  end

  defp maybe_add_reasoning(message, "assistant", metadata) when is_map(metadata) do
    message
    |> maybe_put("reasoning_details", metadata["reasoning_details"])
    |> maybe_put("reasoning", metadata["reasoning"])
  end

  defp maybe_add_reasoning(message, _role, _metadata), do: message

  # An assistant turn that is nothing but tool calls carries no content; the
  # OpenAI shape spells that `null`, not `""`.
  defp content_or_nil("", [_ | _]), do: nil
  defp content_or_nil(text, _), do: text

  defp to_tool_call(%{"functionCall" => call}) do
    %{
      "id" => call["id"] || call["name"],
      "type" => "function",
      "function" => %{
        "name" => call["name"],
        # A JSON string here, where Gemini takes a map.
        "arguments" => Jason.encode!(call["args"] || %{})
      }
    }
  end

  defp encode_tool_result(result) when is_binary(result), do: result
  defp encode_tool_result(nil), do: ""
  defp encode_tool_result(result), do: Jason.encode!(result)

  defp wire_role("model"), do: "assistant"
  defp wire_role("assistant"), do: "assistant"
  defp wire_role("system"), do: "system"
  defp wire_role(_), do: "user"

  # --- Response parsing ---

  @doc false
  # Public only so the parsing can be tested against hand-built fixtures;
  # OpenRouter's docs don't pin down the server-tool response shape, so this
  # is the part most likely to need adjusting against the live API.
  def extract_parts(%{"choices" => [choice | _]} = body) do
    message = Map.get(choice, "message") || %{}
    finish_reason = Map.get(choice, "finish_reason")

    parts =
      text_parts(message["content"]) ++
        refusal_parts(message["refusal"]) ++ tool_call_parts(message["tool_calls"])

    metadata =
      %{}
      |> maybe_put("annotations", message["annotations"])
      |> maybe_put("reasoning_details", message["reasoning_details"])
      |> maybe_put("reasoning", message["reasoning"])
      |> maybe_put("refusal", message["refusal"])
      |> maybe_put("usage", Map.get(body, "usage"))

    if parts == [] and finish_reason not in @clean_finishes do
      Logger.error("OpenRouter returned finish reason: #{inspect(finish_reason)} with no content")
      {:error, {:openrouter_error, finish_reason}}
    else
      {:ok, %{parts: parts, metadata: metadata}}
    end
  end

  # OpenRouter can answer 200 with an error object instead of choices.
  def extract_parts(%{"error" => error}) do
    Logger.error("OpenRouter returned an error: #{inspect(error)}")
    {:error, {:openrouter_error, error}}
  end

  def extract_parts(response) do
    Logger.error("Failed to extract parts from OpenRouter response: #{inspect(response)}")
    {:error, :unexpected_response_format}
  end

  defp text_parts(content) when is_binary(content) and content != "", do: [%{"text" => content}]
  defp text_parts(_), do: []

  defp refusal_parts(refusal) when is_binary(refusal) and refusal != "",
    do: [%{"text" => refusal}]

  defp refusal_parts(_), do: []

  defp tool_call_parts(calls) when is_list(calls) do
    Enum.flat_map(calls, fn
      %{"function" => %{"name" => name} = function} = call ->
        [
          %{
            "functionCall" =>
              %{"name" => name, "args" => decode_arguments(function["arguments"])}
              |> maybe_put("id", call["id"])
          }
        ]

      other ->
        Logger.warning("Unrecognized OpenRouter tool call: #{inspect(other)}")
        []
    end)
  end

  defp tool_call_parts(_), do: []

  # Arguments come back as a JSON string. A model can emit malformed JSON here;
  # keep the raw text rather than crashing the turn, so the tool layer refuses
  # it and the model gets a chance to correct itself.
  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) ->
        decoded

      _ ->
        Logger.warning("OpenRouter tool call arguments were not a JSON object")
        %{"_raw" => arguments}
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: arguments
  defp decode_arguments(_), do: %{}

  # --- Shared helpers ---

  defp presence(nil), do: nil
  defp presence([]), do: nil
  defp presence(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
