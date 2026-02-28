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
  Returns the AI response text or an error.
  """
  def message(conversation_id, message, timeout \\ 60_000) do
    GenServer.call(__MODULE__, {:message, conversation_id, message}, timeout)
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
      messages: []
    }

    state = Map.put(state, id, convo)
    {:reply, id, state}
  end

  @impl true
  def handle_call({:message, conversation_id, message}, _from, state) do
    case Map.get(state, conversation_id) do
      nil ->
        {:reply, {:error, :conversation_not_found}, state}

      convo ->
        # Append user message
        user_msg = %{role: "user", parts: [%{text: message}]}
        new_messages = convo.messages ++ [user_msg]

        # Prepare API options
        api_opts = [
          system_prompt: convo.system_prompt,
          temperature: convo.temperature,
          max_output_tokens: convo.max_output_tokens
        ]

        # Call Gemini (using default model for now, can be configured later)
        model = "gemini-2.5-flash"

        case Echo.Agents.API.generate_content(model, new_messages, api_opts) do
          {:ok, response} ->
            # Extract AI text
            case extract_text(response) do
              {:ok, text} ->
                # Append AI message
                ai_msg = %{role: "model", parts: [%{text: text}]}
                updated_convo = %{convo | messages: new_messages ++ [ai_msg]}

                state = Map.put(state, conversation_id, updated_convo)
                {:reply, {:ok, text}, state}

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

  defp extract_text(%{
         "candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]
       }) do
    {:ok, text}
  end

  defp extract_text(response) do
    Logger.error("Failed to extract text from Gemini response: #{inspect(response)}")
    {:error, :unexpected_response_format}
  end
end
