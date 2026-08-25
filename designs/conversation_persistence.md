# Make agent conversations durable and resumable from Postgres

## Context

`Echo.Agents.ConversationServer` (one GenServer per conversation, registered in `Echo.Agents.ConversationRegistry` under a `DynamicSupervisor`) holds a conversation's config *and* its full message history purely in memory. `Echo.Agent.Message` rows in `ai_messages` are written for audit/history-viewing, but nothing ever reads them back to reconstruct a live conversation — `ConversationServer.init/1` always starts `messages: []` from whatever `opts` it was given at creation, and every push to `elixir` deploys straight to prod with no gate, which wipes the entire `DynamicSupervisor`/`Registry` on every deploy.

Concrete user-facing failure, traced through `blogs` (the only real client): `BottomChat.tsx` keeps `conversationId` in React state for the life of the open tab and never persists it (no localStorage), so a full page reload already starts fresh — that's fine. But a mid-session deploy while an author is actively chatting with the editor AI kills the live `ConversationServer` for their `conversationId` while their tab stays open and keeps using it. `ConversationManager.with_process/2` returns `{:error, :conversation_not_found}` on the next message, and `BottomChat.tsx`'s catch-all handler just shows "Sorry, I encountered an error computing that request." and keeps the same (dead) `conversationId` — every subsequent message repeats the same failure until the author manually clicks "New Agent," losing all conversation context. Given deploys happen on every push with no gate, this is a realistic, recurring failure mode, not a hypothetical edge case.

**Decisions:**
1. Turn persistence is **synchronous** (write to Postgres before replying to the caller), trading a few ms of latency per turn for guaranteed ordering and no silently-lost turns.
2. Resume is **fully transparent**: any `message`/`content` call for a conversation id that exists durably but has no live process silently rehydrates it. Zero changes needed in `blogs`.

## Design

### New table + schema: durable conversation config

A `ConversationServer` today receives its config (`system_prompt`, `temperature`, `max_output_tokens`, `thinking_enabled`, `thinking_budget`, `tools`, `model`, `response_modalities`) purely as constructor `opts` — nothing about it survives a process restart except the system prompt, which is (only) stored as a message row. To rehydrate after a full node restart, that config needs its own durable row, created once at conversation-start time, before the process even starts.

`lib/echo/agent/conversation_record.ex` (`Echo.Agent.ConversationRecord`, table `ai_conversations`) — named `ConversationRecord` rather than `Conversation` specifically to avoid colliding with the existing in-memory `Echo.Agents.Conversation` struct (the existing `Echo.Agent` singular / `Echo.Agents` plural split is DB context vs. runtime processes; this keeps following that split):

```elixir
schema "ai_conversations" do
  field :system_prompt, :string
  field :temperature, :float
  field :max_output_tokens, :integer
  field :thinking_enabled, :boolean, default: false
  field :thinking_budget, :integer
  field :tools, :map
  field :model, :string
  field :response_modalities, {:array, :string}
  timestamps(type: :utc_datetime)
end
```

Primary key is the existing conversation id string (the same 16-byte hex id `ConversationManager.start_conversation/1` already generates). No FK to `ai_messages.session_id` — keep the same loose string-matched join the schema already uses elsewhere.

`Echo.Agent` (context) gains:
- `create_conversation/1` — inserts the `ConversationRecord` **and** the system-prompt message row (`role: "system"`) in one call, synchronously. This must be the only place the system-prompt message gets written, so a later rehydration never re-inserts a duplicate system row.
- `get_conversation/1` — `Repo.get(ConversationRecord, id)`, `nil` if absent.
- `delete_conversation/1` — hard-deletes the `ConversationRecord` row (message history in `ai_messages` is left alone, same as today's `kill_conversation/1` behavior).
- `list_messages_by_session/1`: order by `id` ascending instead of `inserted_at` — cheap hardening so replay order is never ambiguous.

### `ConversationManager.start_conversation/1` — persist before starting the process

```elixir
def start_conversation(opts \\ %{}) do
  id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  with {:ok, _record} <- Echo.Agent.create_conversation(Map.put(opts, "session_id", id)),
       {:ok, _pid} <-
         DynamicSupervisor.start_child(Echo.Agents.ConversationSupervisor, {ConversationServer, %{id: id}}) do
    {:ok, id}
  else
    {:error, reason} -> {:error, reason}
  end
end
```

If the DB write fails, the process never starts. The child spec now only carries `%{id: id}`; `ConversationServer.init/1` loads everything else from the DB record, which is what makes "create" and "resume" the same code path.

### `ConversationServer.init/1` — always hydrate from Postgres

```elixir
def init(%{id: id}) do
  case Echo.Agent.get_conversation(id) do
    nil ->
      {:stop, :conversation_not_found}

    record ->
      convo = %Conversation{
        id: id,
        system_prompt: record.system_prompt,
        temperature: record.temperature || 0.7,
        max_output_tokens: record.max_output_tokens,
        thinking_enabled: record.thinking_enabled,
        thinking_budget: record.thinking_budget,
        tools: record.tools,
        model: record.model,
        response_modalities: record.response_modalities,
        messages: Echo.Agent.list_messages_by_session(id) |> replay_into_turns()
      }

      {:ok, %{convo | backend_tools: Echo.Agents.Tools.enabled(convo.tools)}}
  end
end
```

`replay_into_turns/1` drops `role == "system"` rows (the system prompt is threaded separately as `convo.system_prompt`, never as a message turn), then `Enum.chunk_by(& &1.role)` on the remaining ordered rows and maps each chunk to `%{"role" => role, "parts" => Enum.map(chunk, &row_to_part/1)}`. `row_to_part/1` is the exact inverse of the existing `part_to_attrs/1`:

```elixir
defp row_to_part(%{type: "text", content: text}), do: %{"text" => text}
defp row_to_part(%{type: "functionCall", payload: call}), do: %{"functionCall" => call}
defp row_to_part(%{type: "functionResponse", payload: resp}), do: %{"functionResponse" => resp}
defp row_to_part(%{type: "toolCall", payload: part}), do: part
defp row_to_part(%{type: "toolResponse", payload: part}), do: part
defp row_to_part(%{type: "document", payload: data}), do: %{"inlineData" => data}
defp row_to_part(%{type: "unknown", payload: part}), do: part
```

The `Conversation` struct itself is unchanged — same fields, just sourced from the DB record + replayed history instead of raw `opts`. No changes needed to `run_turn/5`'s tool loop, since it already only operates on this same canonical shape.

### `ConversationManager.with_process/2` — transparent resume on a registry miss

```elixir
defp with_process(conversation_id, callback) do
  case Registry.lookup(Echo.Agents.ConversationRegistry, conversation_id) do
    [{pid, _}] ->
      callback.(pid)

    [] ->
      case DynamicSupervisor.start_child(Echo.Agents.ConversationSupervisor, {ConversationServer, %{id: conversation_id}}) do
        {:ok, pid} -> callback.(pid)
        {:error, {:already_started, pid}} -> callback.(pid)
        {:error, :conversation_not_found} -> {:error, :conversation_not_found}
        {:error, reason} -> {:error, reason}
      end
  end
end
```

`init/1` returning `{:stop, :conversation_not_found}` for an id with no durable record makes `start_child` return exactly `{:error, :conversation_not_found}` — the same error shape callers already handle today, so `AIConversationController`/`AgentChatController` need **no changes**. Two concurrent requests racing a resume both call `start_child`; `Registry`'s unique `:via` naming means only one wins and the other gets `{:error, {:already_started, pid}}`.

### `ConversationManager.kill_conversation/1` — delete the durable record, not just the process

```elixir
def kill_conversation(conversation_id) do
  Echo.Agent.delete_conversation(conversation_id)
  with_process(conversation_id, fn pid -> ConversationServer.kill(pid) end)
end
```

Deleting the record first is what stops a killed conversation from being silently resurrected by the auto-resume path.

### Synchronous persistence

Replace `async_store_parts/5`'s `Task.start(fn -> ... end)` body with a direct synchronous loop (no more spawned `Task`) that runs `Echo.Agent.create_message/1` for each part before `run_turn/5`/`do_process_content/2` proceed. A DB failure while persisting the user's message or the model's reply now surfaces as `{:error, {:persistence_failed, reason}}` to the HTTP caller instead of being silently swallowed. No ordering race is possible within a single conversation: each `ConversationServer` already processes one `GenServer.call` at a time, so synchronous writes happen in exact call order.

### Deferred work

The Gemini/OpenRouter multi-provider plan (see `designs/openrouter_provider.md`) is paused, not dropped, in favor of this fix. Once this lands, `tools`/`model` are already stored as opaque `:map`/`:string` on `ConversationRecord`, so adding a `provider` column later is a small additive migration, not a redesign.

## Files touched

- New: `priv/repo/migrations/*_create_ai_conversations.exs`, `lib/echo/agent/conversation_record.ex`
- `lib/echo/agent.ex` — add `create_conversation/1`, `get_conversation/1`, `delete_conversation/1`; change `list_messages_by_session/1`'s `order_by`.
- `lib/echo/agents/conversation_manager.ex` — `start_conversation/1` (persist-then-start), `with_process/2` (resume-on-miss), `kill_conversation/1` (delete record first).
- `lib/echo/agents/conversation_server.ex` — `init/1` (hydrate from DB + replay), new `replay_into_turns/1`/`row_to_part/1`, `async_store_parts/5` → synchronous.
- No changes needed to `ai_conversation_controller.ex`, `agent_chat_controller.ex`, or anything in `blogs`.

## Testing

- `Echo.Agent` context: `create_conversation/1` (writes both the record and the one system message), `get_conversation/1`, `delete_conversation/1`.
- `ConversationServer`/`ConversationManager`: start a conversation, send a message, `GenServer.stop(pid, :normal)` to simulate the process being gone, then send another message through `ConversationManager` and assert it transparently resumes with the prior turn still present. Also assert `kill_conversation/1` followed by any further `message/2` call returns `{:error, :conversation_not_found}` rather than resurrecting it.
- `agent_chat_controller_test.exs`'s existing `:sys.get_state(pid)`-based assertions should keep passing unmodified.
- A persistence-failure case asserting the turn now surfaces `{:error, ...}` instead of silently succeeding.
