defmodule Echo.Agents.API do
  @moduledoc """
  A GenServer that abstracts the Gemini API for generating content.
  It maps Elixir structs and maps to the Gemini REST API JSON shapes.
  """
  use GenServer
  require Logger

  defstruct [:api_key, :http_client]

  # --- Client API ---

  @doc """
  Starts the API GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Calls the Gemini API generateContent endpoint.

  `model` should be a model name like "gemini-2.0-flash"
  `contents` should be a list of maps matching the Content schema:
    [%{role: "user", parts: [%{text: "..."}]}]
  """
  def generate_content(model, contents, opts \\ [], timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:generate_content, model, contents, opts}, timeout)
  end

  @doc """
  Calls the Gemini API to list available models.
  """
  def list_models(timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:list_models}, timeout)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    config = Application.get_env(:echo, __MODULE__, [])
    api_key = Keyword.get(config, :api_key) || Application.get_env(:echo, __MODULE__)[:api_key]
    http_client = Keyword.get(config, :http_client, Finch)

    if is_nil(api_key) || api_key == "" do
      Logger.warning("GEMINI_API_KEY is not set. API calls will fail.")
    end

    {:ok, %__MODULE__{api_key: api_key, http_client: http_client}}
  end

  @impl true
  def handle_call({:list_models}, _, state) do
    if is_nil(state.api_key) || state.api_key == "" do
      {:reply, {:error, :missing_api_key}, state}
    else
      url = "https://generativelanguage.googleapis.com/v1beta/models"

      headers = [
        {"x-goog-api-key", state.api_key}
      ]

      req = state.http_client.build(:get, url, headers)

      case state.http_client.request(req, Echo.Finch) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, decoded} -> {:reply, {:ok, decoded}, state}
            {:error, reason} -> {:reply, {:error, {:json_decode_error, reason, resp_body}}, state}
          end

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("Gemini API Error: [#{status}] #{resp_body}")
          {:reply, {:error, {:api_error, status, resp_body}}, state}

        {:error, exception} ->
          Logger.error("Gemini API Request Failed: #{inspect(exception)}")
          {:reply, {:error, {:request_failed, exception}}, state}
      end
    end
  end

  @impl true
  def handle_call({:generate_content, model, contents, opts}, _from, state) do
    if is_nil(state.api_key) || state.api_key == "" do
      {:reply, {:error, :missing_api_key}, state}
    else
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent"

      headers = [
        {"Content-Type", "application/json"},
        {"x-goog-api-key", state.api_key}
      ]

      payload = %{
        contents: format_contents(contents)
      }

      payload = append_options(payload, opts)

      body = Jason.encode!(payload)

      # Using the http client from state (defaults to Finch)
      req = state.http_client.build(:post, url, headers, body)

      case state.http_client.request(req, Echo.Finch) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, decoded} -> {:reply, {:ok, decoded}, state}
            {:error, reason} -> {:reply, {:error, {:json_decode_error, reason, resp_body}}, state}
          end

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("Gemini API Error: [#{status}] #{resp_body}")
          {:reply, {:error, {:api_error, status, resp_body}}, state}

        {:error, exception} ->
          Logger.error("Gemini API Request Failed: #{inspect(exception)}")
          {:reply, {:error, {:request_failed, exception}}, state}
      end
    end
  end

  # --- Internal Helpers ---

  # Formats the contents to ensure they match Gemini's expected JSON format
  defp format_contents(contents) when is_list(contents) do
    Enum.map(contents, &format_content/1)
  end

  defp format_content(%{role: role, parts: parts}) do
    %{
      role: role,
      parts: Enum.map(parts, &format_part/1)
    }
  end

  # Default role is generic if not specified (sometimes just providing parts is enough)
  defp format_content(%{parts: parts}) do
    %{
      parts: Enum.map(parts, &format_part/1)
    }
  end

  # Only support text, functionCall, functionResponse, inlineData for now
  defp format_part(%{text: _} = part), do: part
  defp format_part(%{functionCall: _} = part), do: part
  defp format_part(%{functionResponse: _} = part), do: part
  defp format_part(%{inlineData: %{mimeType: _, data: _}} = part), do: part

  defp format_part(part) when is_map(part) do
    # Pass through other parts if they match schemas exactly, but warn
    Logger.warning("Unknown part type passed to Gemini API: #{inspect(Map.keys(part))}")
    part
  end

  defp append_options(payload, opts) do
    payload
    |> maybe_add_system_prompt(opts[:system_prompt])
    |> maybe_add_generation_config(opts)
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

    # Add thinkingConfig here later if needed

    if map_size(config) > 0 do
      Map.put(payload, :generationConfig, config)
    else
      payload
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
