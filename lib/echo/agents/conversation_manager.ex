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
            response_modalities: nil,
            messages: []
end

defmodule Echo.Agents.ConversationManager do
  @moduledoc """
  API boundary for conversation management. Uses a DynamicSupervisor
  and Registry to manage one process per conversation.
  """

  alias Echo.Agents.ConversationServer

  @doc """
  Starts a new conversation with the given configuration options.
  Returns the `conversation_id`.
  """
  def start_conversation(opts \\ %{}) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    opts = Map.put(opts, :id, id)

    case DynamicSupervisor.start_child(
           Echo.Agents.ConversationSupervisor,
           {ConversationServer, opts}
         ) do
      {:ok, _pid} ->
        {:ok, id}

      {:error, {:already_started, _pid}} ->
        {:ok, id}

      error ->
        require Logger
        Logger.error("Failed to start conversation #{id}: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Sends a message to a conversation.
  Returns `{:ok, parts}` or an error.
  """
  def message(conversation_id, message, timeout \\ 300_000) do
    with_process(conversation_id, fn pid ->
      ConversationServer.message(pid, message, timeout)
    end)
  end

  @doc """
  Sends content blocks (e.g., function responses) to a conversation.
  Returns `{:ok, parts}` or an error.
  """
  def content(conversation_id, content_blocks, timeout \\ 300_000) do
    with_process(conversation_id, fn pid ->
      ConversationServer.content(pid, content_blocks, timeout)
    end)
  end

  @doc """
  Kills (removes) a conversation process.
  """
  def kill_conversation(conversation_id) do
    with_process(conversation_id, fn pid ->
      ConversationServer.kill(pid)
    end)
  end

  defp with_process(conversation_id, callback) do
    case Registry.lookup(Echo.Agents.ConversationRegistry, conversation_id) do
      [{pid, _}] ->
        callback.(pid)

      [] ->
        {:error, :conversation_not_found}
    end
  end
end
