defmodule Echo.Agents.ConversationServer do
  @moduledoc """
  A GenServer that manages a single conversation in memory.
  """
  use GenServer, restart: :transient
  require Logger

  alias Echo.Agents.Conversation

  # How many times Echo will run a server-side tool and call back for one user turn.
  @max_tool_iterations 5

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

  # The conversation's config and history live durably in Postgres (see
  # `Echo.Agent.ConversationRecord` and `Echo.Agent.create_conversation/2`) so
  # this process can be rebuilt after a crash or a redeploy wipes the
  # registry — `opts` here only ever needs to carry `:id`; everything else is
  # loaded fresh, which is what makes "create" and "resume" the same path.
  @impl true
  def init(opts) do
    id = Map.get(opts, :id) || Map.get(opts, "id")

    case Echo.Agent.get_conversation(id) do
      nil ->
        {:stop, :conversation_not_found}

      record ->
        # The provider is read from the record, not from `opts`, for the same
        # reason as everything else here: a provider held only in memory would
        # quietly revert to the default the first time this process was rebuilt.
        case Echo.Agents.Providers.resolve(record.provider) do
          {:ok, provider} ->
            convo = %Conversation{
              id: id,
              system_prompt: record.system_prompt,
              temperature: record.temperature || 0.7,
              max_output_tokens: record.max_output_tokens,
              thinking_enabled: record.thinking_enabled || false,
              thinking_budget: record.thinking_budget,
              tools: record.tools,
              model: record.model,
              response_modalities: record.response_modalities,
              provider: provider,
              messages: id |> Echo.Agent.list_messages_by_session() |> replay_into_turns()
            }

            # Only tools this conversation actually declared may be run server-side.
            {:ok, %{convo | backend_tools: Echo.Agents.Tools.enabled(convo.tools)}}

          {:error, reason} ->
            {:stop, reason}
        end
    end
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

    # Persisted before the turn runs: a resume must be able to see the user's
    # message even if the model call itself never completes.
    case store_parts(convo.id, "user", parts, convo.model) do
      :ok ->
        case run_turn(new_messages, api_opts, convo, [], 0) do
          {:ok, messages, reply_parts, metadata} ->
            {:reply, {:ok, reply_parts, metadata}, %{convo | messages: messages}}

          # `messages` here is whatever actually made it into Postgres before
          # the failure, never more — the in-memory state has to match the
          # durable one exactly, or a later resume replays a history this
          # process never actually had (see `replay_into_turns/1`).
          {:error, reason, messages} ->
            {:reply, {:error, reason}, %{convo | messages: messages}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, convo}
    end
  end

  # Calls the conversation's provider, and if it asked for a tool Echo owns,
  # runs the tool and calls again with the result. Client-side tools (the blog
  # editor's `edit_text`, for instance) are not in the registry, so they simply
  # come back to the caller.
  #
  # Every turn is persisted before the next model call is made. On failure,
  # returns `{:error, reason, messages}` where `messages` reflects exactly
  # what was durably persisted so far -- never a turn that failed to persist,
  # and never missing a turn that succeeded -- so the caller can always set
  # its in-memory state to match Postgres, whether this call ultimately
  # succeeded or not.
  #
  # The provider hands back canonical parts already extracted from its own
  # wire format, so nothing below this line knows which backend answered.
  defp run_turn(messages, api_opts, convo, acc_parts, depth) do
    case convo.provider.generate_content(messages, api_opts) do
      {:ok, %{parts: ai_parts, metadata: metadata}} ->
        model_messages = messages ++ [%{"role" => "model", "parts" => ai_parts}]

        case store_parts(convo.id, "model", ai_parts, convo.model, metadata) do
          :ok ->
            continue_turn(
              model_messages,
              ai_parts,
              api_opts,
              convo,
              acc_parts ++ ai_parts,
              metadata,
              depth
            )

          {:error, reason} ->
            {:error, reason, messages}
        end

      {:error, reason} ->
        {:error, reason, messages}
    end
  end

  defp continue_turn(messages, ai_parts, api_opts, convo, acc_parts, metadata, depth) do
    case Echo.Agents.Tools.executable_calls(ai_parts, convo.backend_tools) do
      [] ->
        {:ok, messages, acc_parts, metadata}

      calls when depth >= @max_tool_iterations ->
        Logger.warning(
          "Conversation #{convo.id} hit the tool iteration limit with #{length(calls)} pending call(s)"
        )

        {:ok, messages, acc_parts, metadata}

      calls ->
        response_parts = Enum.map(calls, &Echo.Agents.Tools.run/1)

        case store_parts(convo.id, "user", response_parts, convo.model) do
          :ok ->
            tool_messages = messages ++ [%{"role" => "user", "parts" => response_parts}]
            run_turn(tool_messages, api_opts, convo, acc_parts, depth + 1)

          {:error, reason} ->
            {:error, reason, messages}
        end
    end
  end

  @impl true
  def handle_cast(:kill, state) do
    {:stop, :normal, state}
  end

  # --- Internal Helpers ---

  # Written synchronously, before the caller ever sees a reply: a resumed
  # conversation is only as trustworthy as what's actually landed in
  # Postgres, so a write failure here fails the turn rather than being
  # logged and silently dropped.
  defp store_parts(session_id, role, parts, model, metadata \\ %{}) do
    Enum.reduce_while(parts, :ok, fn part, :ok ->
      attrs =
        part_to_attrs(part)
        |> Map.merge(%{session_id: session_id, role: role, model: model, metadata: metadata})

      try do
        case Echo.Agent.create_message(attrs) do
          {:ok, _message} ->
            {:cont, :ok}

          {:error, changeset} ->
            Logger.error("Failed to persist ai_message: #{inspect(changeset.errors)}")
            {:halt, {:error, {:persistence_failed, changeset}}}
        end
      rescue
        e ->
          Logger.error("Exception persisting ai_message: #{inspect(e)}")
          {:halt, {:error, {:persistence_failed, e}}}
      end
    end)
  end

  # Inverse of `part_to_attrs/1`, used to rebuild `messages` from stored rows
  # when a conversation is (re)hydrated in `init/1`.
  defp replay_into_turns(rows) do
    rows
    |> Enum.reject(&(&1.role == "system"))
    |> Enum.chunk_by(& &1.role)
    |> Enum.map(fn [%{role: role} | _] = chunk ->
      %{"role" => role, "parts" => Enum.map(chunk, &row_to_part/1)}
    end)
  end

  defp row_to_part(%{type: "text", content: text}), do: %{"text" => text}
  defp row_to_part(%{type: "functionCall", payload: call}), do: %{"functionCall" => call}
  defp row_to_part(%{type: "functionResponse", payload: resp}), do: %{"functionResponse" => resp}
  defp row_to_part(%{type: "toolCall", payload: part}), do: part
  defp row_to_part(%{type: "toolResponse", payload: part}), do: part
  defp row_to_part(%{type: "document", payload: data}), do: %{"inlineData" => data}
  defp row_to_part(%{type: "unknown", payload: part}), do: part

  defp row_to_part(row) do
    Logger.warning(
      "Unrecognized stored message type while replaying history: #{inspect(row.type)}"
    )

    %{"text" => row.content || ""}
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

  defp part_to_attrs(%{"toolCall" => _} = part) do
    %{type: "toolCall", payload: part}
  end

  defp part_to_attrs(%{"toolResponse" => _} = part) do
    %{type: "toolResponse", payload: part}
  end

  defp part_to_attrs(%{"inlineData" => data}) do
    %{type: "document", payload: data}
  end

  defp part_to_attrs(part) do
    %{type: "unknown", payload: part}
  end
end
