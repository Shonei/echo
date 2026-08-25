defmodule Echo.Agents.Providers.OpenRouterTest do
  # Not async: the provider reads its config from the global application
  # environment, so the stubbed api_key/http_client can't be isolated per test
  # process the way the request/response state in `FakeHTTPClient` is.
  use ExUnit.Case, async: false

  alias Echo.Agents.Providers.OpenRouter
  alias Echo.FakeHTTPClient

  @turns [%{"role" => "user", "parts" => [%{"text" => "hello"}]}]

  describe "build_payload/2" do
    test "puts the system prompt first, as its own message" do
      payload =
        OpenRouter.build_payload(@turns, model: "openai/gpt-5.6-luna", system_prompt: "be brief")

      assert [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hello"}
             ] = payload["messages"]
    end

    test "renames the model role to assistant" do
      turns = [%{"role" => "model", "parts" => [%{"text" => "hi there"}]}]

      payload = OpenRouter.build_payload(turns, model: "openai/gpt-5.6-luna")

      assert [%{"role" => "assistant", "content" => "hi there"}] = payload["messages"]
    end

    test "serialises tool call arguments to a JSON string, not a map" do
      turns = [
        %{
          "role" => "model",
          "parts" => [
            %{
              "functionCall" => %{
                "name" => "http_request",
                "args" => %{"url" => "https://x.dev"},
                "id" => "call_abc"
              }
            }
          ]
        }
      ]

      payload = OpenRouter.build_payload(turns, model: "openai/gpt-5.6-luna")

      assert [%{"role" => "assistant", "content" => nil, "tool_calls" => [call]}] =
               payload["messages"]

      assert call["id"] == "call_abc"
      assert call["type"] == "function"
      assert call["function"]["name"] == "http_request"
      assert call["function"]["arguments"] == ~s({"url":"https://x.dev"})
    end

    test "turns each function response into its own tool message, keyed by id" do
      turns = [
        %{
          "role" => "user",
          "parts" => [
            %{
              "functionResponse" => %{
                "name" => "http_request",
                "id" => "call_abc",
                "response" => %{"status" => 200}
              }
            }
          ]
        }
      ]

      payload = OpenRouter.build_payload(turns, model: "openai/gpt-5.6-luna")

      assert [
               %{
                 "role" => "tool",
                 "tool_call_id" => "call_abc",
                 "content" => ~s({"status":200})
               }
             ] = payload["messages"]
    end

    test "falls back to the tool name when a response carries no id" do
      turns = [
        %{
          "role" => "user",
          "parts" => [%{"functionResponse" => %{"name" => "http_request", "response" => %{}}}]
        }
      ]

      payload = OpenRouter.build_payload(turns, model: "openai/gpt-5.6-luna")

      assert [%{"tool_call_id" => "http_request"}] = payload["messages"]
    end

    test "carries temperature and the token cap, and omits empty tools" do
      payload =
        OpenRouter.build_payload(@turns,
          model: "openai/gpt-5.6-luna",
          temperature: 0.2,
          max_output_tokens: 2048,
          tools: []
        )

      assert payload["temperature"] == 0.2
      assert payload["max_tokens"] == 2048
      refute Map.has_key?(payload, "tools")
    end
  end

  describe "build_function_tools/1" do
    test "wraps canonical declarations flat, keeping lowercase JSON Schema types" do
      declarations = [Echo.Agents.Tools.HttpRequest.declaration()]

      assert [%{"type" => "function", "function" => function}] =
               OpenRouter.build_function_tools(declarations)

      assert function["name"] == "http_request"
      assert function["parameters"]["type"] == "object"
      assert function["parameters"]["properties"]["url"]["type"] == "string"
    end
  end

  describe "extract_parts/1" do
    test "reads text content as a canonical text part" do
      body = %{"choices" => [%{"message" => %{"content" => "hi"}, "finish_reason" => "stop"}]}

      assert {:ok, %{parts: [%{"text" => "hi"}], metadata: %{}}} = OpenRouter.extract_parts(body)
    end

    test "decodes tool call arguments back into a canonical functionCall, id intact" do
      body = %{
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
                    "arguments" => ~s({"url":"https://x.dev"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      assert {:ok, %{parts: [part]}} = OpenRouter.extract_parts(body)

      assert part == %{
               "functionCall" => %{
                 "name" => "http_request",
                 "args" => %{"url" => "https://x.dev"},
                 "id" => "call_abc"
               }
             }
    end

    test "preserves annotations and usage in metadata, which is the audit trail" do
      annotations = [
        %{
          "type" => "url_citation",
          "url_citation" => %{"url" => "https://example.com", "title" => "Example"}
        }
      ]

      body = %{
        "choices" => [
          %{
            "message" => %{"content" => "per the source", "annotations" => annotations},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"total_tokens" => 42, "prompt_tokens" => 10}
      }

      assert {:ok, %{metadata: metadata}} = OpenRouter.extract_parts(body)

      # Verbatim, not reshaped: OpenRouter's docs don't pin these down, so
      # whatever arrives is what gets persisted.
      assert metadata["annotations"] == annotations
      assert metadata["usage"] == %{"total_tokens" => 42, "prompt_tokens" => 10}
    end

    test "keeps a partial reply when the model was cut off mid-answer" do
      body = %{
        "choices" => [
          %{"message" => %{"content" => "as far as I g"}, "finish_reason" => "length"}
        ]
      }

      assert {:ok, %{parts: [%{"text" => "as far as I g"}]}} = OpenRouter.extract_parts(body)
    end

    test "errors on an odd finish reason only when nothing came back" do
      body = %{"choices" => [%{"message" => %{"content" => nil}, "finish_reason" => "error"}]}

      assert {:error, {:openrouter_error, "error"}} = OpenRouter.extract_parts(body)
    end

    test "surfaces an error object returned with a 200" do
      body = %{"error" => %{"code" => 402, "message" => "insufficient credits"}}

      assert {:error, {:openrouter_error, %{"code" => 402}}} = OpenRouter.extract_parts(body)
    end

    test "keeps malformed tool arguments instead of crashing the turn" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "function" => %{"name" => "http_request", "arguments" => "{not json"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      assert {:ok, %{parts: [%{"functionCall" => call}]}} = OpenRouter.extract_parts(body)
      assert call["args"] == %{"_raw" => "{not json"}
    end
  end

  describe "generate_content/2" do
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

    test "sends a bearer token and returns canonical parts" do
      FakeHTTPClient.stub(%{
        "choices" => [%{"message" => %{"content" => "hello back"}, "finish_reason" => "stop"}],
        "usage" => %{"total_tokens" => 7}
      })

      assert {:ok, %{parts: [%{"text" => "hello back"}], metadata: metadata}} =
               OpenRouter.generate_content(@turns, model: "openai/gpt-5.6-luna")

      assert metadata["usage"] == %{"total_tokens" => 7}

      request = FakeHTTPClient.last_request()
      assert request.url == "https://openrouter.ai/api/v1/chat/completions"
      assert {"Authorization", "Bearer test-key"} in request.headers
      assert request.body["model"] == "openai/gpt-5.6-luna"
    end

    test "refuses to guess a model, since OpenRouter has no default" do
      assert OpenRouter.generate_content(@turns, []) == {:error, :missing_model}
      refute FakeHTTPClient.last_request()
    end

    test "reports a non-2xx response rather than treating it as an empty reply" do
      FakeHTTPClient.stub({:ok, %{status: 429, body: ~s({"error":"rate limited"})}})

      assert {:error, {:api_error, 429, _}} =
               OpenRouter.generate_content(@turns, model: "openai/gpt-5.6-luna")
    end
  end

  describe "generate_content/2 without an API key" do
    setup do
      previous = Application.get_env(:echo, OpenRouter, [])
      Application.put_env(:echo, OpenRouter, Keyword.put(previous, :api_key, nil))
      on_exit(fn -> Application.put_env(:echo, OpenRouter, previous) end)
    end

    test "fails before making a request" do
      assert OpenRouter.generate_content(@turns, model: "openai/gpt-5.6-luna") ==
               {:error, :missing_api_key}
    end
  end
end
