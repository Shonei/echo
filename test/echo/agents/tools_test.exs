defmodule Echo.Agents.ToolsTest do
  use ExUnit.Case, async: true

  alias Echo.Agents.Tools
  alias Echo.Agents.Tools.HttpRequest

  describe "tool_config/2" do
    test "wraps known tools as function declarations, defaulting to Gemini" do
      assert %{"functionDeclarations" => [%{"name" => "http_request"}]} =
               Tools.tool_config(["http_request"])
    end

    test "wraps the same tool in the chosen provider's syntax" do
      assert [%{"type" => "function", "function" => %{"name" => "http_request"}}] =
               Tools.tool_config(["http_request"], Echo.Agents.Providers.OpenRouter)
    end

    test "ignores names it does not own" do
      assert Tools.tool_config(["google_search"]) == nil
      assert Tools.tool_config([]) == nil
      assert Tools.tool_config([], Echo.Agents.Providers.OpenRouter) == nil
    end
  end

  describe "HttpRequest.declaration/0" do
    test "is canonical, lowercase-typed JSON Schema" do
      declaration = HttpRequest.declaration()

      assert declaration["parameters"]["type"] == "object"
      assert declaration["parameters"]["properties"]["url"]["type"] == "string"
    end
  end

  describe "enabled/1" do
    test "finds server-executed tools among the declared ones" do
      tools = [
        %{"google_search" => %{}},
        %{"functionDeclarations" => [%{"name" => "edit_text"}, %{"name" => "http_request"}]}
      ]

      assert Tools.enabled(tools) == ["http_request"]
    end

    test "returns nothing for client-only or missing tools" do
      assert Tools.enabled([%{"functionDeclarations" => [%{"name" => "edit_text"}]}]) == []
      assert Tools.enabled(nil) == []
    end

    test "reads OpenRouter's flat declaration shape too" do
      tools = [
        %{"type" => "function", "function" => %{"name" => "edit_text"}},
        %{"type" => "function", "function" => %{"name" => "http_request"}}
      ]

      assert Tools.enabled(tools) == ["http_request"]
    end

    test "never picks up OpenRouter's own server-side tools" do
      # They resolve inside OpenRouter with no client round-trip, so they must
      # not enter Echo's tool loop -- they carry no "function" key to match on.
      tools = [%{"type" => "openrouter:web_search"}, %{"type" => "openrouter:web_fetch"}]

      assert Tools.enabled(tools) == []
    end
  end

  describe "executable_calls/2" do
    test "picks out calls this module can run" do
      parts = [
        %{"text" => "one moment"},
        %{"functionCall" => %{"name" => "http_request", "args" => %{"url" => "https://x.dev"}}}
      ]

      assert [%{"name" => "http_request"}] = Tools.executable_calls(parts, ["http_request"])
    end

    test "leaves client-side tools alone" do
      parts = [%{"functionCall" => %{"name" => "edit_text", "args" => %{}}}]

      assert Tools.executable_calls(parts, ["http_request"]) == []
    end

    test "refuses a call the conversation never declared" do
      parts = [
        %{"functionCall" => %{"name" => "http_request", "args" => %{"url" => "https://x.dev"}}}
      ]

      assert Tools.executable_calls(parts, []) == []
    end
  end

  describe "run/1" do
    test "wraps a refusal as a functionResponse the model can react to" do
      call = %{"name" => "http_request", "args" => %{"url" => "file:///etc/passwd"}}

      assert %{
               "functionResponse" => %{
                 "name" => "http_request",
                 "response" => %{"error" => error}
               }
             } =
               Tools.run(call)

      assert error =~ "http and https"
    end

    test "carries a call's id onto the response, which OpenRouter pairs on" do
      call = %{"name" => "http_request", "args" => %{"url" => "file:///etc/passwd"}, "id" => "c1"}

      assert %{"functionResponse" => %{"id" => "c1", "name" => "http_request"}} = Tools.run(call)
    end

    test "omits the id when the call had none, so Gemini payloads stay clean" do
      call = %{"name" => "http_request", "args" => %{"url" => "file:///etc/passwd"}}

      assert %{"functionResponse" => response} = Tools.run(call)
      refute Map.has_key?(response, "id")
    end
  end

  describe "HttpRequest.validate_url/1" do
    test "allows public hosts" do
      assert {:ok, _} = HttpRequest.validate_url("https://example.com/path?q=1")
    end

    test "rejects non-http schemes" do
      for url <- ["file:///etc/passwd", "ftp://example.com", "gopher://example.com"] do
        assert {:error, reason} = HttpRequest.validate_url(url)
        assert reason =~ "http and https"
      end
    end

    test "rejects loopback, private, and link-local addresses" do
      urls = [
        "http://127.0.0.1/",
        "http://localhost:4000/",
        "http://10.1.2.3/",
        "http://192.168.0.1/",
        "http://172.16.5.4/",
        "http://[::1]/",
        # Cloud metadata endpoint.
        "http://169.254.169.254/latest/meta-data/",
        # IPv4-mapped IPv6 loopback.
        "http://[::ffff:127.0.0.1]/"
      ]

      for url <- urls do
        assert {:error, reason} = HttpRequest.validate_url(url),
               "expected #{url} to be refused"

        assert reason =~ "internal address"
      end
    end

    test "rejects a missing host and a non-string url" do
      assert {:error, _} = HttpRequest.validate_url("https://")
      assert {:error, _} = HttpRequest.validate_url(nil)
    end
  end

  describe "HttpRequest.run/1" do
    test "rejects methods outside the allowlist before making a request" do
      result = HttpRequest.run(%{"url" => "https://example.com", "method" => "TRACE"})

      assert result["error"] =~ "not allowed"
    end

    test "requires a url" do
      assert HttpRequest.run(%{}) |> Map.fetch!("error") =~ "url is required"
    end
  end
end
