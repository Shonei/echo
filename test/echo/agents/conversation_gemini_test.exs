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

  # A turn can make up to six model calls. Before this, each one carried its own
  # fresh 300s `receive_timeout` while the `GenServer.call` waiting on the whole
  # turn also had 300s -- so the turn could outlive its caller, and since a
  # `GenServer.call` timeout exits the caller without telling the server, the
  # turn ran on, persisted everything, and the client got a 500 for work that
  # had completed. One budget for the turn is what stops that.
  test "every model call in a turn draws down one budget instead of resetting it" do
    tools = [Echo.Agents.Tools.declarations(["http_request"], Gemini)]

    # Refused by `HttpRequest.validate_url/1` as an internal address, so the tool
    # returns an error map without touching the network, and the loop continues.
    call = %{
      "functionCall" => %{"name" => "http_request", "args" => %{"url" => "http://127.0.0.1/"}}
    }

    FakeHTTPClient.stub_sequence([
      %{"candidates" => [%{"content" => %{"parts" => [call]}, "finishReason" => "STOP"}]},
      %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "done"}]}, "finishReason" => "STOP"}
        ]
      }
    ])

    {:ok, id} =
      ConversationManager.start_conversation(%{
        "model" => "gemini-3.1-pro-preview",
        "tools" => tools
      })

    assert {:ok, parts, _metadata} = ConversationManager.message(id, "fetch it")
    assert Enum.any?(parts, &match?(%{"text" => "done"}, &1))

    assert [first, second] = Enum.map(FakeHTTPClient.requests(), & &1.opts[:receive_timeout])

    # The bug was both calls getting the provider's own 300_000 default.
    refute first == 300_000
    refute second == 300_000

    assert first > 0
    assert second > 0
    assert second <= first
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
