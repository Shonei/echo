defmodule Echo.Agents.ConversationResumeTest do
  use Echo.DataCase, async: false

  alias Echo.Agents.ConversationManager

  # Force the model call to fail fast and deterministically (`:missing_api_key`)
  # regardless of what's in the ambient environment, so these tests never make
  # a real network call. Resume happens in `ConversationServer.init/1`, which
  # runs before that call, so this doesn't get in the way of what's under test.
  setup do
    for provider <- [Echo.Agents.Providers.Gemini, Echo.Agents.Providers.OpenRouter] do
      previous = Application.get_env(:echo, provider, [])
      Application.put_env(:echo, provider, Keyword.put(previous, :api_key, nil))
      on_exit(fn -> Application.put_env(:echo, provider, previous) end)
    end

    :ok
  end

  describe "resuming a conversation whose process is gone" do
    test "transparently rehydrates config and history from Postgres" do
      {:ok, id} = ConversationManager.start_conversation(%{"system_prompt" => "be nice"})

      # Seed a completed turn directly, exactly the shape a real message
      # exchange would have left via `store_parts/5` -- there's no live model
      # call in this test, so this stands in for one.
      {:ok, _} =
        Echo.Agent.create_message(%{session_id: id, role: "user", type: "text", content: "hi"})

      {:ok, _} =
        Echo.Agent.create_message(%{
          session_id: id,
          role: "model",
          type: "text",
          content: "hello!"
        })

      [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
      GenServer.stop(pid, :normal)
      wait_until_deregistered(id)

      # The turn itself fails (no API key configured, see setup above), but
      # only *after* init/1 has already resumed the process from Postgres.
      assert ConversationManager.message(id, "are you there?") == {:error, :missing_api_key}

      assert [{new_pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
      assert new_pid != pid

      state = :sys.get_state(new_pid)
      assert state.system_prompt == "be nice"

      # The replayed history, plus the just-failed turn's user message --
      # persisted before the (failing) model call, so it's correctly part of
      # the resumed process's state too, not silently dropped.
      assert [
               %{"role" => "user", "parts" => [%{"text" => "hi"}]},
               %{"role" => "model", "parts" => [%{"text" => "hello!"}]},
               %{"role" => "user", "parts" => [%{"text" => "are you there?"}]}
             ] = state.messages
    end
  end

  describe "a turn that fails after the user's message is persisted" do
    test "leaves the live process's in-memory state matching Postgres, not stale" do
      {:ok, id} = ConversationManager.start_conversation(%{})
      [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)

      # No API key configured (see setup above), so the model call always
      # fails right after the user's message is durably persisted.
      assert ConversationManager.message(id, "first") == {:error, :missing_api_key}

      rows = Echo.Agent.list_messages_by_session(id)
      assert [%{role: "user", content: "first"}] = rows

      # The bug this guards against: the process replying with its stale
      # pre-call state on failure, so `messages` stays `[]` here even though
      # Postgres already has the turn -- a later resume would then see a row
      # this live process itself never accounted for.
      assert :sys.get_state(pid).messages == [
               %{"role" => "user", "parts" => [%{"text" => "first"}]}
             ]

      # And it keeps matching turn over turn, not just on the first one.
      assert ConversationManager.message(id, "second") == {:error, :missing_api_key}

      assert :sys.get_state(pid).messages == [
               %{"role" => "user", "parts" => [%{"text" => "first"}]},
               %{"role" => "user", "parts" => [%{"text" => "second"}]}
             ]

      assert length(Echo.Agent.list_messages_by_session(id)) == 2
    end
  end

  describe "the conversation's provider" do
    test "defaults to Gemini when the caller never named one" do
      {:ok, id} = ConversationManager.start_conversation(%{})

      assert [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
      assert :sys.get_state(pid).provider == Echo.Agents.Providers.Gemini
    end

    test "survives the process being restarted" do
      # The whole reason the provider is a column rather than a start-up arg:
      # `init/1` rebuilds its config from Postgres on every resume, and pushes
      # to `elixir` wipe the registry on every deploy. A provider held only in
      # memory would silently revert to Gemini here.
      {:ok, id} = ConversationManager.start_conversation(%{"provider" => "openrouter"})

      [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
      assert :sys.get_state(pid).provider == Echo.Agents.Providers.OpenRouter

      GenServer.stop(pid, :normal)
      wait_until_deregistered(id)

      # Resumes, then fails the turn on the missing OpenRouter key -- which is
      # itself the proof it resumed onto OpenRouter and not the default.
      assert ConversationManager.message(id, "are you there?") == {:error, :missing_api_key}

      assert [{new_pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
      assert new_pid != pid
      assert :sys.get_state(new_pid).provider == Echo.Agents.Providers.OpenRouter
    end

    test "refuses a provider it doesn't know instead of falling back" do
      assert {:error, {:unknown_provider, "hal9000"}} =
               ConversationManager.start_conversation(%{"provider" => "hal9000"})
    end

    test "leaves no durable record behind for a conversation that never started" do
      # `start_conversation/1` writes the record before starting the process,
      # so a start that fails in `init/1` has to clean up after itself.
      before = Echo.Repo.aggregate(Echo.Agent.ConversationRecord, :count)

      assert {:error, _} = ConversationManager.start_conversation(%{"provider" => "hal9000"})

      assert Echo.Repo.aggregate(Echo.Agent.ConversationRecord, :count) == before
    end
  end

  describe "killing a conversation" do
    test "prevents it from being resurrected by a later message" do
      {:ok, id} = ConversationManager.start_conversation(%{})

      ConversationManager.kill_conversation(id)
      # `kill/1` stops the process via an async cast; wait for it to actually
      # be gone before asserting on the state that leaves behind.
      wait_until_deregistered(id)

      assert ConversationManager.message(id, "hello") == {:error, :conversation_not_found}
    end
  end

  # `Registry` removes a dead process's entry once it processes that
  # process's `:DOWN` message, which lands sometime after `GenServer.stop/2`
  # returns (or after a `:kill` cast is handled) rather than atomically with
  # it -- poll instead of asserting immediately.
  defp wait_until_deregistered(id, attempts \\ 50) do
    case Registry.lookup(Echo.Agents.ConversationRegistry, id) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(5)
        wait_until_deregistered(id, attempts - 1)

      _ ->
        flunk("conversation #{id} was never deregistered")
    end
  end
end
