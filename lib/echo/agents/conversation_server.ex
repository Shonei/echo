defmodule Echo.Agents.ConversationServer do
  @moduledoc """
  A GenServer that manages a single conversation in memory.
  """
  use GenServer, restart: :transient
  require Logger

  alias Echo.Agents.Conversation

  # How many times Echo will run a server-side tool and call back for one user turn.
  @max_tool_iterations 5

  # Wall-clock budget for one user turn, shared by every model call inside it.
  #
  # This exists because the turn and a single model call used to carry the same
  # 300s timeout, one from `GenServer.call` and one from the provider's
  # `receive_timeout`. A turn makes up to six model calls (`run_turn/5` at depths
  # 0..#{@max_tool_iterations}) plus tool rounds in between, so the inner budget
  # could reach ~30 minutes against an outer 300s -- and since the two were equal,
  # a single full-length model call was already enough to blow the outer one.
  #
  # Losing that race is not merely slow, it is wrong: a `GenServer.call` timeout
  # exits the *caller* and never tells this process, so the turn kept running,
  # persisted every message, and replied into the void. The client saw a 500 for
  # work that had completed and was durable, and its next message resumed a
  # history it was never shown. Retrying the 500 appended the user turn twice.
  #
  # So the budget is set once per turn and every model call draws down from it.
  # `Echo.Agents.ConversationManager`'s default call timeout must stay above this
  # (it is 300_000, leaving 30s of slack) so the deadline here always fires first
  # and the caller gets a real reply instead of an exit.
  #
  # This bounds model calls, which dominate. A tool round can still overshoot by
  # its own bounded amount -- `Echo.Agents.Tools.HttpRequest` caps each request at
  # 15s -- which the slack absorbs. The real fix is to stop holding a
  # `GenServer.call` across the whole loop at all; see `designs/skills.md`, whose
  # approval gate needs a turn that can pause and resume anyway.
  @turn_budget_ms 270_000

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
              variable_scope: record.variable_scope,
              resolver: Map.get(opts, :resolver),
              messages: id |> Echo.Agent.list_messages_by_session() |> replay_into_turns()
            }

            # Resolved once, here, from durable state. Everything downstream
            # works from these structs rather than from the registry, which is
            # what gives a tool somewhere to carry per-conversation settings.
            {:ok, %{convo | toolset: Echo.Agents.Tools.build(record.tool_config, convo.tools)}}

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

    # Prepare API options. `:deadline` is the one clock for this whole turn; see
    # `@turn_budget_ms`. Providers ignore it and read `:timeout`, which
    # `run_turn/5` derives from it before each call.
    api_opts = [
      system_prompt: convo.system_prompt,
      temperature: convo.temperature,
      max_output_tokens: convo.max_output_tokens,
      tools: convo.tools,
      thinking_enabled: convo.thinking_enabled,
      thinking_budget: convo.thinking_budget,
      response_modalities: convo.response_modalities,
      model: convo.model,
      deadline: System.monotonic_time(:millisecond) + @turn_budget_ms
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
    # Each call gets what is left of the turn, never a fresh 300s of its own.
    # `continue_turn/7` refuses to recurse once the budget is spent, so what
    # reaches here is positive.
    call_opts = Keyword.put(api_opts, :timeout, remaining_ms(api_opts))

    case convo.provider.generate_content(messages, call_opts) do
      {:ok, %{parts: ai_parts, metadata: metadata}} ->
        model_turn =
          %{"role" => "model", "parts" => ai_parts}
          |> maybe_put_turn_metadata(metadata)

        model_messages = messages ++ [model_turn]

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
    # A gated call is not executed and not answered: the turn ends, every call
    # comes back to the caller in `acc_parts`, and the process is freed. That is
    # the path a client-side tool already takes, so nothing new happens here --
    # what makes it an approval rather than a dead end is the resume, which
    # `designs/skills.md` Phase 2 adds.
    case Echo.Agents.Tools.partition_calls(ai_parts, convo.toolset) do
      {[], parked} when parked != [] ->
        Logger.info(
          "Conversation #{convo.id} parked #{length(parked)} call(s) awaiting a decision"
        )

        {:ok, messages, acc_parts, metadata}

      {[], []} ->
        {:ok, messages, acc_parts, metadata}

      {calls, _parked} when depth >= @max_tool_iterations ->
        Logger.warning(
          "Conversation #{convo.id} hit the tool iteration limit with #{length(calls)} pending call(s)"
        )

        {:ok, messages, acc_parts, metadata}

      {calls, _parked} ->
        # Checked before running the tools, not after, so a tool round is never
        # started with no time left to use its result. Out of budget is the same
        # outcome as the iteration limit above, and for the same reason: every
        # turn is already durable, so stopping here loses nothing and lets the
        # caller get a real reply before its own timeout expires.
        if remaining_ms(api_opts) > 0 do
          run_tools(calls, messages, api_opts, convo, acc_parts, depth)
        else
          Logger.warning(
            "Conversation #{convo.id} ran out of turn budget with #{length(calls)} pending call(s)"
          )

          {:ok, messages, acc_parts, metadata}
        end
    end
  end

  # `Tools.run_all/4` is where a `$.name` the model wrote becomes the value the
  # tool runs with, and where it becomes a placeholder again on the way back.
  # Both halves happen strictly between the two `store_parts/5` calls that
  # bracket this: `run_turn/5` has already persisted the `functionCall` with the
  # placeholder intact, and the responses below are scrubbed before they are
  # persisted here. `messages` is untouched by either -- the resolved copy never
  # leaves `run_all/4`'s stack -- so the in-memory history and Postgres stay
  # identical, which is what `replay_into_turns/1` depends on.
  defp run_tools(calls, messages, api_opts, convo, acc_parts, depth) do
    case Echo.Agents.Tools.run_all(calls, convo.toolset, convo.variable_scope, convo.resolver) do
      {:ok, response_parts} ->
        case store_parts(convo.id, "user", response_parts, convo.model) do
          :ok ->
            tool_messages = messages ++ [%{"role" => "user", "parts" => response_parts}]
            run_turn(tool_messages, api_opts, convo, acc_parts, depth + 1)

          {:error, reason} ->
            {:error, reason, messages}
        end

      # The scope could not be answered, so nothing ran. `messages` is exactly
      # what Postgres holds: the model turn with its unanswered `functionCall`.
      {:error, reason} ->
        {:error, reason, messages}
    end
  end

  # What is left of this turn's budget. A turn always carries a `:deadline`
  # (`do_process_content/2` sets it); the fallback keeps this total for any
  # caller that builds opts by hand, such as a test.
  defp remaining_ms(api_opts) do
    case Keyword.get(api_opts, :deadline) do
      nil -> @turn_budget_ms
      deadline -> deadline - System.monotonic_time(:millisecond)
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
      |> maybe_put_turn_metadata(turn_metadata(chunk))
    end)
  end

  defp turn_metadata(rows) do
    Enum.find_value(rows, %{}, fn row ->
      if is_map(row.metadata) and map_size(row.metadata) > 0, do: row.metadata
    end)
  end

  defp maybe_put_turn_metadata(turn, metadata)
       when is_map(metadata) and map_size(metadata) > 0,
       do: Map.put(turn, "metadata", metadata)

  defp maybe_put_turn_metadata(turn, _metadata), do: turn

  @function_call_part_fields ~w(thought thoughtSignature)

  defp row_to_part(%{type: "text", content: text}), do: %{"text" => text}

  defp row_to_part(%{type: "functionCall", payload: call}) do
    call_part = %{"functionCall" => Map.drop(call, @function_call_part_fields)}
    copy_present_fields(call, call_part, @function_call_part_fields)
  end

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

  defp part_to_attrs(%{"functionCall" => call} = part) do
    payload = copy_present_fields(part, call, @function_call_part_fields)
    %{type: "functionCall", payload: payload}
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

  defp copy_present_fields(source, target, fields) do
    Enum.reduce(fields, target, fn field, acc ->
      if Map.has_key?(source, field), do: Map.put(acc, field, source[field]), else: acc
    end)
  end
end
