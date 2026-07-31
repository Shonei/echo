defmodule Echo.Agents.APITest do
  use ExUnit.Case, async: true

  alias Echo.Agents.API
  alias Echo.Agents.Presets

  @contents [%{"role" => "user", "parts" => [%{"text" => "hello"}]}]

  describe "build_payload/2 tool config" do
    test "sets includeServerSideToolInvocations when built-ins meet function calling" do
      tools = [
        %{"functionDeclarations" => [%{"name" => "edit_text"}]},
        %{"google_search" => %{}}
      ]

      payload = API.build_payload(@contents, tools: tools)

      assert payload.toolConfig == %{includeServerSideToolInvocations: true}
    end

    test "sets it for the editor preset, which mixes both" do
      opts = Presets.editor() |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)

      payload = API.build_payload(@contents, opts)

      assert payload.toolConfig == %{includeServerSideToolInvocations: true}
    end

    test "leaves it off when only function declarations are used" do
      tools = [%{"functionDeclarations" => [%{"name" => "http_request"}]}]

      payload = API.build_payload(@contents, tools: tools)

      refute Map.has_key?(payload, :toolConfig)
      assert payload.tools == tools
    end

    test "leaves it off when only built-ins are used" do
      tools = [%{"google_search" => %{}}, %{"url_context" => %{}}]

      payload = API.build_payload(@contents, tools: tools)

      refute Map.has_key?(payload, :toolConfig)
    end

    test "omits tools entirely when none are given" do
      payload = API.build_payload(@contents, [])

      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :toolConfig)
    end

    test "omits an empty tools list rather than sending []" do
      payload = API.build_payload(@contents, tools: [])

      refute Map.has_key?(payload, :tools)
    end

    test "the photographer preset sends no tools key at all" do
      opts =
        Presets.photographer() |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)

      payload = API.build_payload(@contents, opts)

      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :toolConfig)
      assert payload.generationConfig.responseModalities == ["TEXT", "IMAGE"]
    end
  end

  describe "build_payload/2 generation config" do
    test "sends the thinking budget under thinkingConfig.thinkingBudget" do
      payload =
        API.build_payload(@contents, thinking_enabled: true, thinking_budget: 1024)

      assert payload.generationConfig.thinkingConfig == %{thinkingBudget: 1024}
    end

    test "ignores the budget when thinking is off" do
      payload = API.build_payload(@contents, thinking_budget: 1024)

      refute Map.has_key?(payload, :generationConfig)
    end

    test "carries temperature, token cap, and modalities" do
      payload =
        API.build_payload(@contents,
          temperature: 0.1,
          max_output_tokens: 2048,
          response_modalities: ["TEXT", "IMAGE"]
        )

      assert payload.generationConfig.temperature == 0.1
      assert payload.generationConfig.maxOutputTokens == 2048
      assert payload.generationConfig.responseModalities == ["TEXT", "IMAGE"]
    end

    test "puts the system prompt in systemInstruction" do
      payload = API.build_payload(@contents, system_prompt: "be brief")

      assert payload.systemInstruction == %{parts: [%{text: "be brief"}]}
    end
  end
end
