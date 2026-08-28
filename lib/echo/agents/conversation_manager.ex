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
            # Resolved once at `init/1` into `Echo.Agents.Tool` structs, so the
            # execution path never consults the compile-time registry.
            toolset: [],
            model: nil,
            response_modalities: nil,
            provider: nil,
            variable_scope: nil,
            # Who answers `$.name` for this conversation. Injected rather than
            # looked up from the bottom of the call stack, so it shows up in
            # `:sys.get_state/1` and `Echo.Agents.Variables` stays pure.
            resolver: nil,
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

  The configuration is persisted to Postgres (`Echo.Agent.create_conversation/2`)
  before the process is started, so the DB write, not the in-memory process,
  is the source of truth `Echo.Agents.ConversationServer.init/1` hydrates
  from — this is what lets a conversation be transparently resumed (see
  `with_process/2`) after its process is gone.
  """
  def start_conversation(opts \\ %{}) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    with {:ok, _record} <- Echo.Agent.create_conversation(id, opts),
         {:ok, _pid} <- start_child(id) do
      {:ok, id}
    else
      {:error, {:already_started, _pid}} ->
        {:ok, id}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to start conversation #{id}: #{inspect(reason)}")
        # Only reachable once the record was already created (a
        # `create_conversation/2` failure short-circuits the `with` before
        # this branch): don't leave a durable record behind for a
        # conversation that never actually got a live process.
        Echo.Agent.delete_conversation(id)
        {:error, reason}
    end
  end

  # Every path that spins up a server goes through here -- `start_conversation/1`
  # and the resume in `with_process/2` -- which is what lets the resolver be
  # injected without a resumed conversation losing it. It can be injected at all
  # only because it is one module for the whole system; anything that varies per
  # conversation has to be durable instead, which is why the *scope* is a column
  # and the resolver is not.
  defp start_child(id) do
    DynamicSupervisor.start_child(
      Echo.Agents.ConversationSupervisor,
      {ConversationServer, %{id: id, resolver: resolver()}}
    )
  end

  # Wired here rather than looked up from the bottom of the call stack, so
  # `Echo.Agents.Variables` reads no global state and the dependency shows up in
  # `:sys.get_state/1`. A plain constant because there is exactly one resolver;
  # `Echo.Agents.VariableResolver` is the seam, and a second implementation
  # would make this a lookup, not a rewrite.
  @resolver Echo.Skills.Variables

  defp resolver, do: @resolver

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
  Kills (removes) a conversation process and deletes its durable record.

  Deleting the record (not just the process) is what makes the delete stick:
  without it, the next `message/2` or `content/2` call for this id would
  just transparently resume the conversation `with_process/2` just deleted.
  """
  def kill_conversation(conversation_id) do
    Echo.Agent.delete_conversation(conversation_id)

    with_process(conversation_id, fn pid ->
      ConversationServer.kill(pid)
    end)
  end

  # Resumes a conversation transparently when its process isn't running: if
  # a durable record still exists for this id, `start_child/1` starts a fresh
  # `ConversationServer`, whose `init/1` rehydrates config + history from
  # Postgres. If no durable record exists (never created, or deleted via
  # `kill_conversation/1`), `init/1` stops with `:conversation_not_found`,
  # which surfaces here as the same error callers already handled before
  # resume existed.
  defp with_process(conversation_id, callback) do
    case Registry.lookup(Echo.Agents.ConversationRegistry, conversation_id) do
      [{pid, _}] ->
        callback.(pid)

      [] ->
        case start_child(conversation_id) do
          {:ok, pid} -> callback.(pid)
          {:error, {:already_started, pid}} -> callback.(pid)
          {:error, :conversation_not_found} -> {:error, :conversation_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
