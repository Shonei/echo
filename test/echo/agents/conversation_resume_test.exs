defmodule Echo.Agents.ConversationResumeTest do
  use Echo.DataCase, async: false

  alias Echo.Agents.ConversationManager

  # Force the Gemini call to fail fast and deterministically (`:missing_api_key`)
  # regardless of what's in the ambient environment, so these tests never make
  # a real network call. Resume happens in `ConversationServer.init/1`, which
  # runs before that call, so this doesn't get in the way of what's under test.
  setup do
    previous = Application.get_env(:echo, Echo.Agents.API, [])
    Application.put_env(:echo, Echo.Agents.API, Keyword.put(previous, :api_key, nil))
    on_exit(fn -> Application.put_env(:echo, Echo.Agents.API, previous) end)
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

      assert [
               %{"role" => "user", "parts" => [%{"text" => "hi"}]},
               %{"role" => "model", "parts" => [%{"text" => "hello!"}]}
             ] = state.messages
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
