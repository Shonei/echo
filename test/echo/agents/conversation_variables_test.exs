defmodule Echo.Agents.ConversationVariablesTest do
  # async: false -- both the HTTP stub and the resolver stub live in the
  # application environment.
  use Echo.DataCase, async: false

  alias Echo.Agents.ConversationManager
  alias Echo.Agents.Providers.Gemini
  alias Echo.Agents.Tools
  alias Echo.FakeHTTPClient
  alias Echo.StubVariableResolver

  setup do
    FakeHTTPClient.reset()
    StubVariableResolver.reset()
    previous_gemini = Application.get_env(:echo, Gemini, [])
    previous_resolver = Application.get_env(:echo, :variable_resolver)

    Application.put_env(
      :echo,
      Gemini,
      Keyword.merge(previous_gemini, api_key: "test-key", http_client: FakeHTTPClient)
    )

    Application.put_env(:echo, :variable_resolver, StubVariableResolver)

    on_exit(fn ->
      Application.put_env(:echo, Gemini, previous_gemini)
      Application.put_env(:echo, :variable_resolver, previous_resolver)
      FakeHTTPClient.reset()
      StubVariableResolver.reset()
    end)
  end

  defp stub_call_then_text(args) do
    call = %{"functionCall" => %{"name" => "http_request", "args" => args}}

    FakeHTTPClient.stub_sequence([
      %{"candidates" => [%{"content" => %{"parts" => [call]}, "finishReason" => "STOP"}]},
      %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "done"}]}, "finishReason" => "STOP"}
        ]
      }
    ])
  end

  defp start(scope) do
    {:ok, id} =
      ConversationManager.start_conversation(%{
        "model" => "gemini-3.1-pro-preview",
        "tools" => [Tools.tool_config(["http_request"], Gemini)],
        "variable_scope" => scope
      })

    id
  end

  # `HttpRequest.validate_url/1` refuses a loopback host without touching the
  # network, and quotes the host it refused -- so the tool's own error proves
  # the resolved value really did reach it, with no extra stubbing.
  test "the placeholder is persisted and the value is scrubbed back out" do
    StubVariableResolver.put("stub:hosts", %{"internal_host" => {"localhost", :sensitive}})
    stub_call_then_text(%{"url" => "http://$.internal_host/status"})

    id = start("stub:hosts")
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    rows = Echo.Agent.list_messages_by_session(id)
    call_row = Enum.find(rows, &(&1.type == "functionCall"))
    response_row = Enum.find(rows, &(&1.type == "functionResponse"))

    # What every later model request replays, and what an approval UI shows.
    assert call_row.payload["args"]["url"] == "http://$.internal_host/status"

    error = response_row.payload["response"]["error"]
    assert error =~ "$.internal_host"
    refute error =~ "localhost"
  end

  test "a plain value reaches the tool but is not scrubbed, because that would corrupt" do
    StubVariableResolver.put("stub:hosts", %{"internal_host" => {"localhost", :plain}})
    stub_call_then_text(%{"url" => "http://$.internal_host/status"})

    id = start("stub:hosts")
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    rows = Echo.Agent.list_messages_by_session(id)
    response_row = Enum.find(rows, &(&1.type == "functionResponse"))

    # This is the Phase 1 behaviour for every real variable: substituted on the
    # way out, left alone on the way back.
    assert response_row.payload["response"]["error"] =~ "localhost"
  end

  test "a variable the scope does not know comes back as a tool error the model can act on" do
    StubVariableResolver.put("stub:hosts", %{})
    stub_call_then_text(%{"url" => "http://$.nope/status"})

    id = start("stub:hosts")
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    rows = Echo.Agent.list_messages_by_session(id)
    response_row = Enum.find(rows, &(&1.type == "functionResponse"))

    assert response_row.payload["response"]["error"] =~ "$.nope"
  end

  test "a conversation with no scope leaves $. alone" do
    stub_call_then_text(%{"url" => "http://$.items/status"})

    id = start(nil)
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    rows = Echo.Agent.list_messages_by_session(id)
    response_row = Enum.find(rows, &(&1.type == "functionResponse"))

    # Unresolved and passed through as text, so the existing agent chat -- where
    # `$.` is far likelier to be a jq path -- behaves exactly as it did.
    assert response_row.payload["response"]["error"] =~ "$.items"
  end

  test "the scope survives a restart, because it is read back from Postgres" do
    StubVariableResolver.put("stub:hosts", %{"internal_host" => {"localhost", :sensitive}})

    FakeHTTPClient.stub(%{
      "candidates" => [
        %{"content" => %{"parts" => [%{"text" => "hi"}]}, "finishReason" => "STOP"}
      ]
    })

    id = start("stub:hosts")
    assert {:ok, _, _} = ConversationManager.message(id, "hello")

    [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
    GenServer.stop(pid, :normal)

    stub_call_then_text(%{"url" => "http://$.internal_host/status"})
    assert {:ok, _, _} = ConversationManager.message(id, "now check it")

    response_row =
      id |> Echo.Agent.list_messages_by_session() |> Enum.find(&(&1.type == "functionResponse"))

    assert response_row.payload["response"]["error"] =~ "$.internal_host"
  end
end
