defmodule Echo.Agents.ConversationOpenRouterTest do
  @moduledoc """
  End-to-end cover for a conversation running on OpenRouter: provider dispatch,
  the server-side tool loop, and what lands in `ai_messages`.

  Not async — the fake HTTP client and the provider's api_key both live in the
  global application environment.
  """
  use Echo.DataCase, async: false

  alias Echo.Agents.ConversationManager
  alias Echo.Agents.Providers.OpenRouter
  alias Echo.FakeHTTPClient

  setup do
    FakeHTTPClient.reset()
    previous = Application.get_env(:echo, OpenRouter, [])

    Application.put_env(
      :echo,
      OpenRouter,
      Keyword.merge(previous, api_key: "test-key", http_client: FakeHTTPClient)
    )

    on_exit(fn ->
      Application.put_env(:echo, OpenRouter, previous)
      FakeHTTPClient.reset()
    end)
  end

  defp text_reply(content, extra \\ %{}) do
    message = Map.merge(%{"content" => content}, extra)
    %{"choices" => [%{"message" => message, "finish_reason" => "stop"}]}
  end

  describe "a plain turn" do
    test "routes through OpenRouter and returns canonical parts" do
      FakeHTTPClient.stub(text_reply("hello from openrouter"))

      {:ok, id} =
        ConversationManager.start_conversation(%{
          "provider" => "openrouter",
          "model" => "openai/gpt-5.6-luna",
          "system_prompt" => "be brief"
        })

      assert {:ok, [%{"text" => "hello from openrouter"}], _metadata} =
               ConversationManager.message(id, "hi")

      request = FakeHTTPClient.last_request()
      assert request.url == "https://openrouter.ai/api/v1/chat/completions"
      assert request.body["model"] == "openai/gpt-5.6-luna"

      # The system prompt is a message on this provider, not a separate field.
      assert [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hi"}
             ] = request.body["messages"]
    end

    test "persists annotations from OpenRouter's server-side tools" do
      annotations = [
        %{
          "type" => "url_citation",
          "url_citation" => %{"url" => "https://example.com", "title" => "Example"}
        }
      ]

      FakeHTTPClient.stub(text_reply("per Example", %{"annotations" => annotations}))

      {:ok, id} =
        ConversationManager.start_conversation(%{
          "provider" => "openrouter",
          "model" => "openai/gpt-5.6-luna",
          "tools" => [%{"type" => "openrouter:web_search"}]
        })

      assert {:ok, _parts, metadata} = ConversationManager.message(id, "check example.com")
      assert metadata["annotations"] == annotations

      # The audit requirement: they're in Postgres, not just in the reply.
      assert [_user, model_row] = Echo.Agent.list_messages_by_session(id)
      assert model_row.role == "model"
      assert model_row.metadata["annotations"] == annotations
    end

    test "OpenRouter's own server tools never enter Echo's tool loop" do
      FakeHTTPClient.stub(text_reply("done"))

      {:ok, id} =
        ConversationManager.start_conversation(%{
          "provider" => "openrouter",
          "model" => "openai/gpt-5.6-luna",
          "tools" => [%{"type" => "openrouter:web_search"}]
        })

      [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
      assert :sys.get_state(pid).backend_tools == []
    end
  end

  describe "a turn that calls a tool Echo runs" do
    test "loops the result back and pairs it to the call by id" do
      # The tool refuses a loopback URL before making any request, so the loop
      # runs for real without touching the network.
      tool_call = %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => %{
                    "name" => "http_request",
                    "arguments" => ~s({"url":"http://127.0.0.1/"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      FakeHTTPClient.stub_sequence([tool_call, text_reply("I couldn't reach that.")])

      {:ok, id} =
        ConversationManager.start_conversation(%{
          "provider" => "openrouter",
          "model" => "openai/gpt-5.6-luna",
          "tools" => [
            %{"type" => "function", "function" => %{"name" => "http_request"}}
          ]
        })

      assert {:ok, parts, _metadata} = ConversationManager.message(id, "fetch localhost")

      # Both the call and the final text come back to the caller.
      assert [%{"functionCall" => call}, %{"text" => "I couldn't reach that."}] = parts
      assert call["id"] == "call_abc"

      # Two model calls were made: the second carries the tool result, keyed by
      # the id OpenRouter needs to match it to the call it answers.
      assert [_first, second] = FakeHTTPClient.requests()

      assert Enum.any?(second.body["messages"], fn message ->
               message["role"] == "tool" and message["tool_call_id"] == "call_abc"
             end)

      # And the whole exchange is in the audit trail, in order.
      rows = Echo.Agent.list_messages_by_session(id)
      assert Enum.map(rows, & &1.type) == ["text", "functionCall", "functionResponse", "text"]
      assert Enum.map(rows, & &1.role) == ["user", "model", "user", "model"]

      response_row = Enum.at(rows, 2)
      assert response_row.payload["id"] == "call_abc"
    end

    test "restores reasoning details from Postgres for a later model call" do
      reasoning_details = [
        %{
          "type" => "reasoning.encrypted",
          "data" => "opaque-reasoning-from-openrouter"
        }
      ]

      tool_call = %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "reasoning_details" => reasoning_details,
              "tool_calls" => [
                %{
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => %{"name" => "edit_text", "arguments" => "{}"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      FakeHTTPClient.stub(tool_call)

      {:ok, id} =
        ConversationManager.start_conversation(%{
          "provider" => "openrouter",
          "model" => "anthropic/claude-sonnet-4"
        })

      assert {:ok, [%{"functionCall" => _}], %{"reasoning_details" => ^reasoning_details}} =
               ConversationManager.message(id, "edit this")

      assert [_user_row, model_row] = Echo.Agent.list_messages_by_session(id)
      assert model_row.metadata["reasoning_details"] == reasoning_details

      [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)
      GenServer.stop(pid, :normal)
      wait_until_deregistered(id)

      FakeHTTPClient.stub(text_reply("done"))

      assert {:ok, [%{"text" => "done"}], _metadata} =
               ConversationManager.message(id, "continue")

      assert Enum.any?(FakeHTTPClient.last_request().body["messages"], fn message ->
               message["role"] == "assistant" and
                 message["reasoning_details"] == reasoning_details
             end)
    end
  end

  describe "a conversation with no model" do
    test "fails the turn rather than guessing one" do
      {:ok, id} = ConversationManager.start_conversation(%{"provider" => "openrouter"})

      assert ConversationManager.message(id, "hi") == {:error, :missing_model}
      assert FakeHTTPClient.requests() == []
    end
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
