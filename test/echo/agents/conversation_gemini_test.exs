defmodule Echo.Agents.ConversationGeminiTest do
  use Echo.DataCase, async: false

  alias Echo.Agents.ConversationManager
  alias Echo.Agents.Providers.Gemini
  alias Echo.FakeHTTPClient

  setup do
    FakeHTTPClient.reset()
    previous = Application.get_env(:echo, Gemini, [])

    Application.put_env(
      :echo,
      Gemini,
      Keyword.merge(previous, api_key: "test-key", http_client: FakeHTTPClient)
    )

    on_exit(fn ->
      Application.put_env(:echo, Gemini, previous)
      FakeHTTPClient.reset()
    end)
  end

  test "persists and restores a function call's thought signature" do
    function_call = %{
      "functionCall" => %{"name" => "edit_text", "args" => %{"text" => "updated"}},
      "thoughtSignature" => "opaque-signature-from-gemini"
    }

    FakeHTTPClient.stub(%{
      "candidates" => [
        %{"content" => %{"parts" => [function_call]}, "finishReason" => "STOP"}
      ]
    })

    {:ok, id} =
      ConversationManager.start_conversation(%{
        "model" => "gemini-3.1-pro-preview"
      })

    assert {:ok, [^function_call], %{}} = ConversationManager.message(id, "edit this")

    assert [_user_row, model_row] = Echo.Agent.list_messages_by_session(id)
    assert model_row.type == "functionCall"
    assert model_row.payload["thoughtSignature"] == "opaque-signature-from-gemini"

    [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
    GenServer.stop(pid, :normal)
    wait_until_deregistered(id)

    FakeHTTPClient.stub(%{
      "candidates" => [
        %{"content" => %{"parts" => [%{"text" => "done"}]}, "finishReason" => "STOP"}
      ]
    })

    assert {:ok, [%{"text" => "done"}], %{}} = ConversationManager.message(id, "continue")

    assert [{new_pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
    assert new_pid != pid

    state = :sys.get_state(new_pid)
    assert Enum.at(state.messages, 1) == %{"role" => "model", "parts" => [function_call]}

    assert Enum.at(FakeHTTPClient.last_request().body["contents"], 1) ==
             %{"role" => "model", "parts" => [function_call]}
  end

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
