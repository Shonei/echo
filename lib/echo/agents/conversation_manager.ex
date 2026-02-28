defmodule Echo.Agents.Conversation do
  @moduledoc """
  Defines the structure for a conversation.
  """
  defstruct id: nil,
            system_prompt: nil,
            temperature: 0.7,
            max_output_tokens: nil,
            thinking_enabled: false,
            thinking_budget: nil,
            tools: nil,
            model: nil,
            messages: []
end

defmodule Echo.Agents.ConversationManager do
  @moduledoc """
  A GenServer that manages multiple conversations in memory.
  """
  use GenServer
  require Logger

  alias Echo.Agents.Conversation

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a new conversation with the given configuration options.
  Returns the `conversation_id`.
  """
  def start_conversation(opts \\ %{}) do
    GenServer.call(__MODULE__, {:start_conversation, opts})
  end

  @doc """
  Sends a message to a conversation. Appends to history, calls the API, and updates history.
  Returns `{:ok, parts}` or an error.
  """
  def message(conversation_id, message, timeout \\ 60_000) do
    GenServer.call(__MODULE__, {:message, conversation_id, message}, timeout)
  end

  @doc """
  Sends content blocks (e.g., function responses) to a conversation.
  Returns `{:ok, parts}` or an error.
  """
  def content(conversation_id, content_blocks, timeout \\ 60_000) do
    GenServer.call(__MODULE__, {:content, conversation_id, content_blocks}, timeout)
  end

  @doc """
  Kills (removes) a conversation from memory cache.
  """
  def kill_conversation(conversation_id) do
    GenServer.cast(__MODULE__, {:kill_conversation, conversation_id})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    # Map from conversation_id -> %Echo.Agents.Conversation{}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_conversation, opts}, _from, state) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    convo = %Conversation{
      id: id,
      system_prompt: Map.get(opts, :system_prompt) || Map.get(opts, "system_prompt"),
      temperature: Map.get(opts, :temperature, 0.7) || Map.get(opts, "temperature", 0.7),
      max_output_tokens: Map.get(opts, :max_output_tokens) || Map.get(opts, "max_output_tokens"),
      thinking_enabled:
        Map.get(opts, :thinking_enabled, false) || Map.get(opts, "thinking_enabled", false),
      thinking_budget: Map.get(opts, :thinking_budget) || Map.get(opts, "thinking_budget"),
      tools: Map.get(opts, :tools) || Map.get(opts, "tools"),
      model: Map.get(opts, :model) || Map.get(opts, "model"),
      messages: []
    }

    state = Map.put(state, id, convo)
    {:reply, id, state}
  end

  @impl true
  def handle_call({:message, conversation_id, message}, _from, state) do
    do_process_content(conversation_id, [%{text: message}], state)
  end

  @impl true
  def handle_call({:content, conversation_id, content_blocks}, _from, state) do
    do_process_content(conversation_id, content_blocks, state)
  end

  defp do_process_content(conversation_id, parts, state) do
    case Map.get(state, conversation_id) do
      nil ->
        {:reply, {:error, :conversation_not_found}, state}

      convo ->
        # Append user message parts
        user_msg = %{role: "user", parts: parts}
        new_messages = convo.messages ++ [user_msg]

        # Prepare API options
        api_opts = [
          system_prompt: convo.system_prompt,
          temperature: convo.temperature,
          max_output_tokens: convo.max_output_tokens,
          tools: convo.tools
        ]

        # Call Gemini
        model =
          convo.model ||
            Application.get_env(:echo, Echo.Agents.API, [])[:model] || "gemini-2.5-flash"

        case Echo.Agents.API.generate_content(model, new_messages, api_opts) do
          {:ok, response} ->
            # Extract AI parts directly
            case extract_parts(response) do
              {:ok, ai_parts} ->
                # Append AI message
                ai_msg = %{role: "model", parts: ai_parts}
                updated_convo = %{convo | messages: new_messages ++ [ai_msg]}

                state = Map.put(state, conversation_id, updated_convo)
                {:reply, {:ok, ai_parts}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast({:kill_conversation, conversation_id}, state) do
    state = Map.delete(state, conversation_id)
    {:noreply, state}
  end

  # --- Internal Helpers ---

  defp extract_parts(%{
         "candidates" => [%{"content" => %{"parts" => parts}} | _]
       }) do
    # Because Elixir decode returns string keys, we normalize them to atoms or just return as is.
    # The simplest is returning them as lists of maps (mostly using string keys).
    {:ok, Enum.map(parts, &normalize_keys/1)}
  end

  defp extract_parts(response) do
    Logger.error("Failed to extract parts from Gemini response: #{inspect(response)}")
    {:error, :unexpected_response_format}
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {
        if(is_binary(k), do: String.to_atom(k), else: k),
        if(is_map(v), do: normalize_keys(v), else: v)
      }
    end)
  end
end
