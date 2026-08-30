defmodule Echo.Agents.ToolsTest do
  use ExUnit.Case, async: true

  alias Echo.Agents.Tool
  alias Echo.Agents.Tools
  alias Echo.Agents.Tools.HttpRequest

  describe "declarations/2" do
    test "wraps known tools as function declarations, defaulting to Gemini" do
      assert %{"functionDeclarations" => [%{"name" => "http_request"}]} =
               Tools.declarations(["http_request"])
    end

    test "wraps the same tool in the chosen provider's syntax" do
      assert [%{"type" => "function", "function" => %{"name" => "http_request"}}] =
               Tools.declarations(["http_request"], Echo.Agents.Providers.OpenRouter)
    end

    test "ignores names it does not own" do
      assert Tools.declarations(["google_search"]) == nil
      assert Tools.declarations([]) == nil
      assert Tools.declarations([], Echo.Agents.Providers.OpenRouter) == nil
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
        %{
          "functionDeclarations" => [
            %{"name" => "http_request"},
            %{"name" => "edit_text"}
          ]
        }
      ]

      assert Tools.enabled(tools) == ["http_request"]
    end

    test "returns nothing for client-only or missing tools" do
      assert Tools.enabled([%{"functionDeclarations" => [%{"name" => "edit_text"}]}]) == []
      assert Tools.enabled(nil) == []
    end

    test "reads OpenRouter's flat declaration shape too" do
      tools = [
        %{"type" => "function", "function" => %{"name" => "http_request"}},
        %{"type" => "function", "function" => %{"name" => "edit_text"}}
      ]

      assert Tools.enabled(tools) == ["http_request"]
    end

    test "never picks up OpenRouter's own server-side tools" do
      assert Tools.enabled([%{"type" => "openrouter:web_search"}]) == []
    end
  end

  describe "build/2" do
    test "derives an ungated toolset from the declarations when there is no config" do
      declared = [%{"functionDeclarations" => [%{"name" => "http_request"}]}]

      assert [%Tool{name: "http_request", executor: {:module, HttpRequest}, gate: :never}] =
               Tools.build(nil, declared)

      # An empty map means the same thing, so a caller that sends `%{}` rather
      # than omitting the column is not silently left with no tools.
      assert Tools.build(%{}, declared) == Tools.build(nil, declared)
    end

    test "an explicit config is authoritative and carries per-tool settings" do
      config = %{
        "http_request" => %{"gate" => "mutations", "config" => %{"allowed_hosts" => ["a.dev"]}}
      }

      assert [tool] = Tools.build(config, [])
      assert tool.gate == :mutations
      assert tool.config == %{"allowed_hosts" => ["a.dev"]}
    end

    test "settings may be omitted entirely" do
      assert [%Tool{gate: :never, config: %{}}] = Tools.build(%{"http_request" => %{}}, [])
    end

    test "drops a name with nothing to back it, rather than keeping a broken entry" do
      # Keeping it would be worse than useless: an unresolvable tool behaves
      # exactly like a client-side one, so the call would fall through to the
      # caller and look identical to one waiting on a human.
      assert Tools.build(%{"no_such_tool" => %{}}, []) == []
    end

    test "an unrecognised gate fails closed" do
      assert [%Tool{gate: :always}] = Tools.build(%{"http_request" => %{"gate" => "yolo"}}, [])
    end
  end

  describe "partition_calls/2" do
    defp toolset(gate),
      do: [%Tool{name: "http_request", executor: {:module, HttpRequest}, gate: gate}]

    defp call(args), do: %{"functionCall" => %{"name" => "http_request", "args" => args}}

    test "runs everything when nothing is gated" do
      assert {[%{"name" => "http_request"}], []} =
               Tools.partition_calls([call(%{"url" => "https://x.dev"})], toolset(:never))
    end

    test "parks everything when a tool is always gated" do
      assert {[], [%{"name" => "http_request"}]} =
               Tools.partition_calls([call(%{"url" => "https://x.dev"})], toolset(:always))
    end

    test ":mutations asks the tool to classify the call" do
      reads = call(%{"url" => "https://x.dev"})
      writes = call(%{"url" => "https://x.dev", "method" => "POST"})

      assert {[_], []} = Tools.partition_calls([reads], toolset(:mutations))
      assert {[], [_]} = Tools.partition_calls([writes], toolset(:mutations))
    end

    test "one gated call parks its whole turn, siblings included" do
      reads = call(%{"url" => "https://x.dev"})
      writes = call(%{"url" => "https://x.dev", "method" => "DELETE"})

      # Answering some of a turn's calls and not others is a shape OpenRouter
      # rejects outright, and it would fire the read's side effect while waiting
      # on a decision about its neighbour.
      assert {[], parked} = Tools.partition_calls([reads, writes], toolset(:mutations))
      assert length(parked) == 2
    end

    test "leaves client-side tools alone, in neither list" do
      parts = [
        %{"functionCall" => %{"name" => "edit_text", "args" => %{}}},
        call(%{"url" => "https://x.dev"})
      ]

      assert {[%{"name" => "http_request"}], []} = Tools.partition_calls(parts, toolset(:never))
    end

    test "a call for a tool this conversation never got is not executable" do
      assert Tools.executable_calls([call(%{"url" => "https://x.dev"})], []) == []
    end
  end

  describe "run_all/4" do
    setup do
      {:ok, toolset: [%Tool{name: "http_request", executor: {:module, HttpRequest}}]}
    end

    test "wraps a refusal as a functionResponse the model can react to", %{toolset: toolset} do
      call = %{"name" => "http_request", "args" => %{"url" => "file:///etc/passwd"}}

      assert {:ok, [%{"functionResponse" => %{"response" => %{"error" => error}}}]} =
               Tools.run_all([call], toolset, nil, nil)

      assert error =~ "http and https"
    end

    test "carries a call's id onto the response, which OpenRouter pairs on", %{toolset: toolset} do
      call = %{"name" => "http_request", "args" => %{"url" => "file:///x"}, "id" => "c1"}

      assert {:ok, [%{"functionResponse" => %{"id" => "c1", "name" => "http_request"}}]} =
               Tools.run_all([call], toolset, nil, nil)
    end

    test "omits the id when the call had none, so Gemini payloads stay clean", %{
      toolset: toolset
    } do
      call = %{"name" => "http_request", "args" => %{"url" => "file:///x"}}

      assert {:ok, [%{"functionResponse" => response}]} = Tools.run_all([call], toolset, nil, nil)
      refute Map.has_key?(response, "id")
    end
  end

  describe "HttpRequest.mutating?/1" do
    test "a read is not a mutation" do
      refute HttpRequest.mutating?(%{"url" => "https://x.dev"})
      refute HttpRequest.mutating?(%{"url" => "https://x.dev", "method" => "get"})
      refute HttpRequest.mutating?(%{"url" => "https://x.dev", "method" => "HEAD"})
    end

    test "anything that can write is" do
      for method <- ~w(POST PUT PATCH DELETE post) do
        assert HttpRequest.mutating?(%{"url" => "https://x.dev", "method" => method}),
               "expected #{method} to classify as mutating"
      end
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
