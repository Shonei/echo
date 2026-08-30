defmodule Echo.Agents.ConversationVariablesTest do
  # async: false -- FakeHTTPClient's stub lives in the application environment,
  # because the process that sets it is not the one that makes the call.
  use Echo.DataCase, async: false

  alias Echo.Agents.ConversationManager
  alias Echo.Agents.Providers.Gemini
  alias Echo.Agents.Tools
  alias Echo.FakeHTTPClient
  alias Echo.Skills.Variables

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
        "tools" => [Tools.declarations(["http_request"], Gemini)],
        "tool_config" => %{"http_request" => %{}},
        "variable_scope" => scope
      })

    id
  end

  # The registry drops an entry on the DOWN message, so a lookup straight after
  # `GenServer.stop/2` can still hand back the dead pid -- and calling it exits.
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

  defp response_row(id) do
    id |> Echo.Agent.list_messages_by_session() |> Enum.find(&(&1.type == "functionResponse"))
  end

  # `HttpRequest.validate_url/1` refuses a loopback host without touching the
  # network, and quotes the host it refused -- so the tool's own error proves
  # the resolved value really did reach it, with no extra stubbing.
  test "a secret's placeholder is persisted and the value is scrubbed back out" do
    skill = skill_fixture()
    variable_fixture(skill, %{name: "internal_host", kind: "secret", value: "localhost"})
    stub_call_then_text(%{"url" => "http://$.internal_host/status"})

    id = start(Variables.scope(skill))
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    call_row =
      id |> Echo.Agent.list_messages_by_session() |> Enum.find(&(&1.type == "functionCall"))

    # What every later model request replays, and what an approval UI shows.
    assert call_row.payload["args"]["url"] == "http://$.internal_host/status"

    error = response_row(id).payload["response"]["error"]
    assert error =~ "$.internal_host"
    refute error =~ "localhost"
  end

  test "a config value reaches the tool but is not scrubbed, because that would corrupt" do
    skill = skill_fixture()
    variable_fixture(skill, %{name: "internal_host", value: "localhost"})
    stub_call_then_text(%{"url" => "http://$.internal_host/status"})

    id = start(Variables.scope(skill))
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    assert response_row(id).payload["response"]["error"] =~ "localhost"
  end

  test "a variable the scope does not know comes back as a tool error the model can act on" do
    skill = skill_fixture()
    stub_call_then_text(%{"url" => "http://$.nope/status"})

    id = start(Variables.scope(skill))
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    assert response_row(id).payload["response"]["error"] =~ "$.nope"
  end

  test "a conversation with no scope leaves $. alone" do
    stub_call_then_text(%{"url" => "http://$.items/status"})

    id = start(nil)
    assert {:ok, _parts, _metadata} = ConversationManager.message(id, "check it")

    # Unresolved and passed through as text, so the existing agent chat -- where
    # `$.` is far likelier to be a jq path -- behaves exactly as it did.
    assert response_row(id).payload["response"]["error"] =~ "$.items"
  end

  test "the scope and the resolver both survive a restart" do
    skill = skill_fixture()
    variable_fixture(skill, %{name: "internal_host", kind: "secret", value: "localhost"})

    FakeHTTPClient.stub(%{
      "candidates" => [
        %{"content" => %{"parts" => [%{"text" => "hi"}]}, "finishReason" => "STOP"}
      ]
    })

    id = start(Variables.scope(skill))
    assert {:ok, _, _} = ConversationManager.message(id, "hello")

    [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
    GenServer.stop(pid, :normal)
    wait_until_deregistered(id)

    # The scope comes back from Postgres; the resolver is re-injected by
    # `start_child/1`, which is the path a resume takes too.
    stub_call_then_text(%{"url" => "http://$.internal_host/status"})
    assert {:ok, _, _} = ConversationManager.message(id, "now check it")

    error = response_row(id).payload["response"]["error"]
    assert error =~ "$.internal_host"
    refute error =~ "localhost"
  end
end
