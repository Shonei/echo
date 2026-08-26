defmodule Echo.Agents.Providers.GeminiTest do
  use ExUnit.Case, async: true

  alias Echo.Agents.Providers.Gemini
  alias Echo.Agents.Presets

  @contents [%{"role" => "user", "parts" => [%{"text" => "hello"}]}]

  describe "build_payload/2 tool config" do
    test "sets includeServerSideToolInvocations when built-ins meet function calling" do
      tools = [
        %{"functionDeclarations" => [%{"name" => "edit_text"}]},
        %{"google_search" => %{}}
      ]

      payload = Gemini.build_payload(@contents, tools: tools)

      assert payload.toolConfig == %{includeServerSideToolInvocations: true}
    end

    test "sets it for the editor preset, which mixes both" do
      opts = Presets.editor() |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)

      payload = Gemini.build_payload(@contents, opts)

      assert payload.toolConfig == %{includeServerSideToolInvocations: true}
    end

    test "leaves it off when only function declarations are used" do
      tools = [%{"functionDeclarations" => [%{"name" => "http_request"}]}]

      payload = Gemini.build_payload(@contents, tools: tools)

      refute Map.has_key?(payload, :toolConfig)
      assert payload.tools == tools
    end

    test "leaves it off when only built-ins are used" do
      tools = [%{"google_search" => %{}}, %{"url_context" => %{}}]

      payload = Gemini.build_payload(@contents, tools: tools)

      refute Map.has_key?(payload, :toolConfig)
    end

    test "omits tools entirely when none are given" do
      payload = Gemini.build_payload(@contents, [])

      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :toolConfig)
    end

    test "omits an empty tools list rather than sending []" do
      payload = Gemini.build_payload(@contents, tools: [])

      refute Map.has_key?(payload, :tools)
    end

    test "the photographer preset sends no tools key at all" do
      opts =
        Presets.photographer() |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)

      payload = Gemini.build_payload(@contents, opts)

      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :toolConfig)
      assert payload.generationConfig.responseModalities == ["TEXT", "IMAGE"]
    end
  end

  describe "build_payload/2 part formatting" do
    test "strips an id another provider needs and Gemini rejects" do
      contents = [
        %{
          "role" => "model",
          "parts" => [
            %{"functionCall" => %{"name" => "http_request", "args" => %{}, "id" => "call_abc"}}
          ]
        },
        %{
          "role" => "user",
          "parts" => [
            %{
              "functionResponse" => %{
                "name" => "http_request",
                "response" => %{},
                "id" => "call_abc"
              }
            }
          ]
        }
      ]

      payload = Gemini.build_payload(contents, [])

      assert [
               %{"parts" => [%{"functionCall" => call}]},
               %{"parts" => [%{"functionResponse" => response}]}
             ] = payload.contents

      assert call == %{"name" => "http_request", "args" => %{}}
      assert response == %{"name" => "http_request", "response" => %{}}
    end

    test "preserves Gemini's thought signature on a function call" do
      contents = [
        %{
          "role" => "model",
          "parts" => [
            %{
              "functionCall" => %{
                "name" => "http_request",
                "args" => %{},
                "id" => "call_abc"
              },
              "thoughtSignature" => "opaque-signature-from-gemini"
            }
          ]
        }
      ]

      payload = Gemini.build_payload(contents, [])

      assert [
               %{
                 "parts" => [
                   %{
                     "functionCall" => %{"name" => "http_request", "args" => %{}},
                     "thoughtSignature" => "opaque-signature-from-gemini"
                   }
                 ]
               }
             ] = payload.contents
    end
  end

  describe "build_function_tools/1" do
    test "nests declarations and upper-cases the whole parameters tree" do
      declarations = [Echo.Agents.Tools.HttpRequest.declaration()]

      assert %{"functionDeclarations" => [declaration]} =
               Gemini.build_function_tools(declarations)

      assert declaration["name"] == "http_request"
      assert declaration["parameters"]["type"] == "OBJECT"
      assert declaration["parameters"]["properties"]["url"]["type"] == "STRING"
      assert declaration["parameters"]["properties"]["headers"]["type"] == "OBJECT"
    end

    test "recurses into nested array items" do
      declarations = [
        %{
          "name" => "edit_text",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "replacements" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{"old_text" => %{"type" => "string"}}
                }
              }
            }
          }
        }
      ]

      assert %{"functionDeclarations" => [declaration]} =
               Gemini.build_function_tools(declarations)

      replacements = declaration["parameters"]["properties"]["replacements"]
      assert replacements["type"] == "ARRAY"
      assert replacements["items"]["type"] == "OBJECT"
      assert replacements["items"]["properties"]["old_text"]["type"] == "STRING"
    end

    test "leaves enum values alone -- only type names are upper-cased" do
      declarations = [
        %{
          "name" => "http_request",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"method" => %{"type" => "string", "enum" => ["GET", "post"]}}
          }
        }
      ]

      assert %{"functionDeclarations" => [declaration]} =
               Gemini.build_function_tools(declarations)

      assert declaration["parameters"]["properties"]["method"]["enum"] == ["GET", "post"]
    end
  end

  describe "build_payload/2 generation config" do
    test "sends the thinking budget under thinkingConfig.thinkingBudget" do
      payload =
        Gemini.build_payload(@contents, thinking_enabled: true, thinking_budget: 1024)

      assert payload.generationConfig.thinkingConfig == %{thinkingBudget: 1024}
    end

    test "ignores the budget when thinking is off" do
      payload = Gemini.build_payload(@contents, thinking_budget: 1024)

      refute Map.has_key?(payload, :generationConfig)
    end

    test "carries temperature, token cap, and modalities" do
      payload =
        Gemini.build_payload(@contents,
          temperature: 0.1,
          max_output_tokens: 2048,
          response_modalities: ["TEXT", "IMAGE"]
        )

      assert payload.generationConfig.temperature == 0.1
      assert payload.generationConfig.maxOutputTokens == 2048
      assert payload.generationConfig.responseModalities == ["TEXT", "IMAGE"]
    end

    test "puts the system prompt in systemInstruction" do
      payload = Gemini.build_payload(@contents, system_prompt: "be brief")

      assert payload.systemInstruction == %{parts: [%{text: "be brief"}]}
    end
  end
end
