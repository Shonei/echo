defmodule Echo.Agents.ConversationServer do
  @moduledoc """
  A GenServer that manages a single conversation in memory.
  """
  use GenServer, restart: :transient
  require Logger

  alias Echo.Agents.Conversation

  # --- Client API ---

  def start_link(opts) do
    # Ensure ID is present
    id = Map.get(opts, :id) || Map.get(opts, "id")

    if is_nil(id) do
      raise ArgumentError, "Conversation :id is required"
    end

    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  def message(pid, message, timeout \\ 120_000) do
    GenServer.call(pid, {:message, message}, timeout)
  end

  def content(pid, content_blocks, timeout \\ 120_000) do
    GenServer.call(pid, {:content, content_blocks}, timeout)
  end

  def kill(pid) do
    GenServer.cast(pid, :kill)
  end

  # --- Process Registration ---

  defp via_tuple(id) do
    {:via, Registry, {Echo.Agents.ConversationRegistry, id}}
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    id = Map.get(opts, :id) || Map.get(opts, "id")

    convo = %Conversation{
      id: id,
      system_prompt: Map.get(opts, :system_prompt) || Map.get(opts, "system_prompt"),
      temperature: Map.get(opts, :temperature) || Map.get(opts, "temperature") || 0.7,
      max_output_tokens: Map.get(opts, :max_output_tokens) || Map.get(opts, "max_output_tokens"),
      thinking_enabled:
        Map.get(opts, :thinking_enabled, false) || Map.get(opts, "thinking_enabled", false),
      thinking_budget: Map.get(opts, :thinking_budget) || Map.get(opts, "thinking_budget"),
      tools: Map.get(opts, :tools) || Map.get(opts, "tools"),
      model: Map.get(opts, :model) || Map.get(opts, "model"),
      response_modalities:
        Map.get(opts, :response_modalities) || Map.get(opts, "response_modalities"),
      messages: []
    }

    if convo.system_prompt do
      async_store_parts(id, "system", [%{"text" => convo.system_prompt}], convo.model)
    end

    {:ok, convo}
  end

  @impl true
  def handle_call({:message, message}, _from, convo) do
    do_process_content([%{"text" => message}], convo)
  end

  @impl true
  def handle_call({:content, content_blocks}, _from, convo) do
    do_process_content(content_blocks, convo)
  end

  defp do_process_content(parts, convo) do
    # Append user message parts
    user_msg = %{"role" => "user", "parts" => parts}
    new_messages = convo.messages ++ [user_msg]

    # Fire and forget DB storage for the user message
    async_store_parts(convo.id, "user", parts, convo.model)

    # Prepare API options
    api_opts = [
      system_prompt: convo.system_prompt,
      temperature: convo.temperature,
      max_output_tokens: convo.max_output_tokens,
      tools: convo.tools,
      thinking_enabled: convo.thinking_enabled,
      thinking_budget: convo.thinking_budget,
      response_modalities: convo.response_modalities,
      model: convo.model
    ]

    # Call Gemini
    case Echo.Agents.API.generate_content(new_messages, api_opts) do
      {:ok, response} ->
        # Extract AI parts directly
        case extract_parts(response) do
          {:ok, ai_parts} ->
            # Append AI message
            ai_msg = %{"role" => "model", "parts" => ai_parts}
            updated_convo = %{convo | messages: new_messages ++ [ai_msg]}

            # Fire and forget DB storage for the AI response
            async_store_parts(convo.id, "model", ai_parts, convo.model)

            {:reply, {:ok, ai_parts}, updated_convo}

          {:error, reason} ->
            {:reply, {:error, reason}, convo}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, convo}
    end
  end

  @impl true
  def handle_cast(:kill, state) do
    {:stop, :normal, state}
  end

  # --- Internal Helpers ---

  defp extract_parts(%{
         "candidates" => [%{"content" => %{"parts" => parts}} | _]
       }) do
    {:ok, parts}
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

  # Log silently by rescuing errors
  defp async_store_parts(session_id, role, parts, model) do
    Task.start(fn ->
      Enum.each(parts, fn part ->
        attrs =
          part_to_attrs(part)
          |> Map.merge(%{
            session_id: session_id,
            role: role,
            model: model
          })

        try do
          case Echo.Agent.create_message(attrs) do
            {:ok, _} ->
              :ok

            {:error, changeset} ->
              Logger.warning("Failed to store async ai_message: #{inspect(changeset.errors)}")
          end
        rescue
          e ->
            Logger.error("Exception storing async ai_message: #{inspect(e)}")
        end
      end)
    end)
  end

  defp part_to_attrs(%{"text" => text}) do
    %{type: "text", content: text}
  end

  defp part_to_attrs(%{"functionCall" => call}) do
    %{type: "functionCall", payload: call}
  end

  defp part_to_attrs(%{"functionResponse" => resp}) do
    %{type: "functionResponse", payload: resp}
  end

  defp part_to_attrs(%{"inlineData" => data}) do
    %{type: "document", payload: data}
  end

  defp part_to_attrs(part) do
    %{type: "unknown", payload: part}
  end
end
