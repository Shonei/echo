defmodule EchoWeb.AgentChatControllerTest do
  use EchoWeb.ConnCase, async: false

  alias Echo.Agents.Providers.OpenRouter
  alias Echo.FakeHTTPClient

  setup %{conn: conn} do
    Application.put_env(:echo, :auth, username: "agent", password: "secret")

    # Rendering the form lists OpenRouter's models, so keep that off the network.
    FakeHTTPClient.reset()
    previous_openrouter = Application.get_env(:echo, OpenRouter, [])

    Application.put_env(
      :echo,
      OpenRouter,
      Keyword.merge(previous_openrouter, api_key: "test-key", http_client: FakeHTTPClient)
    )

    FakeHTTPClient.stub(%{
      "data" => [
        %{
          "id" => "openai/gpt-5.6-luna",
          "name" => "OpenAI: GPT-5.6 Luna",
          "supported_parameters" => ["tools", "temperature"]
        },
        %{
          "id" => "some/text-only-model",
          "name" => "Some: Text Only",
          "supported_parameters" => ["temperature"]
        }
      ]
    })

    on_exit(fn ->
      Application.delete_env(:echo, :auth)
      Application.put_env(:echo, OpenRouter, previous_openrouter)
      FakeHTTPClient.reset()
    end)

    conn =
      put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("agent", "secret"))

    {:ok, conn: conn}
  end

  describe "new" do
    test "offers every option the conversation API supports", %{conn: conn} do
      html = conn |> get(~p"/agent-chat/new") |> html_response(200)

      for field <- [
            "agent[provider]",
            "agent[model]",
            "agent[openrouter_model]",
            "agent[openrouter_model_custom]",
            "agent[system_prompt]",
            "agent[temperature]",
            "agent[max_output_tokens]",
            "agent[thinking_enabled]",
            "agent[thinking_budget]",
            "agent[response_modalities][image]",
            "agent[tools][google_search]",
            "agent[tools][url_context]",
            "agent[tools][web_search]",
            "agent[tools][web_fetch]",
            "agent[tools][http_request]",
            "agent[web_search_engine]",
            "agent[web_fetch_engine]"
          ] do
        assert html =~ field, "expected the form to expose #{field}"
      end
    end

    test "lists OpenRouter's live models, split by whether they can call tools", %{conn: conn} do
      html = conn |> get(~p"/agent-chat/new") |> html_response(200)

      assert html =~ "openai/gpt-5.6-luna"
      assert html =~ "some/text-only-model"
      assert html =~ "Supports tools"
      assert html =~ "Text only"
    end

    test "still renders a usable form when OpenRouter's model list is unreachable", %{conn: conn} do
      FakeHTTPClient.stub({:error, %Mint.TransportError{reason: :econnrefused}})

      html = conn |> get(~p"/agent-chat/new") |> html_response(200)

      # The slug field is the fallback, so the form is never a dead end.
      assert html =~ "agent[openrouter_model_custom]"
      assert html =~ "reach OpenRouter"
      refute html =~ ~s(name="agent[openrouter_model]")
    end
  end

  describe "create" do
    test "wires the selected options into the conversation", %{conn: conn} do
      params = %{
        "agent" => %{
          "model" => "gemini-3.7-flash",
          "temperature" => "0.2",
          "max_output_tokens" => "2048",
          "thinking_enabled" => "true",
          "thinking_budget" => "1024",
          "response_modalities" => %{"text" => "true"},
          "tools" => %{"google_search" => "true", "http_request" => "true"}
        }
      }

      conn = post(conn, ~p"/agent-chat", params)
      state = conversation_state(conn)

      assert state.model == "gemini-3.7-flash"
      assert state.temperature == 0.2
      assert state.max_output_tokens == 2048
      assert state.thinking_enabled
      assert state.thinking_budget == 1024
      assert state.response_modalities == ["TEXT"]

      assert %{"google_search" => %{}} in state.tools

      assert Enum.any?(state.tools, fn
               %{"functionDeclarations" => [%{"name" => "http_request"}]} -> true
               _ -> false
             end)
    end

    test "leaves optional settings unset when the form is left empty", %{conn: conn} do
      params = %{
        "agent" => %{
          "model" => "gemini-3.7-flash",
          "temperature" => "0.7",
          "max_output_tokens" => "",
          "thinking_budget" => "",
          "response_modalities" => %{"text" => "true"},
          "tools" => %{}
        }
      }

      conn = post(conn, ~p"/agent-chat", params)
      state = conversation_state(conn)

      assert state.max_output_tokens == nil
      assert state.thinking_budget == nil
      assert state.thinking_enabled == false
      assert state.tools == nil
    end
  end

  describe "create on OpenRouter" do
    test "builds the server tools from the checkboxes, with their options", %{conn: conn} do
      params = %{
        "agent" => %{
          "provider" => "openrouter",
          "openrouter_model" => "openai/gpt-5.6-luna",
          "temperature" => "0.3",
          "tools" => %{"web_search" => "true", "web_fetch" => "true", "http_request" => "true"},
          "web_search_engine" => "exa",
          "web_search_max_results" => "3",
          "web_fetch_engine" => "openrouter",
          "web_fetch_max_content_tokens" => "50000"
        }
      }

      conn = post(conn, ~p"/agent-chat", params)
      state = conversation_state(conn)

      assert state.provider == Echo.Agents.Providers.OpenRouter
      assert state.model == "openai/gpt-5.6-luna"

      assert %{
               "type" => "openrouter:web_search",
               "parameters" => %{"engine" => "exa", "max_results" => 3}
             } in state.tools

      assert %{
               "type" => "openrouter:web_fetch",
               "parameters" => %{"engine" => "openrouter", "max_content_tokens" => 50_000}
             } in state.tools

      # Echo's own tool is declared in OpenRouter's flat syntax, and is the only
      # one of the three the tool loop will actually run.
      assert %{"type" => "function", "function" => %{"name" => "http_request"}} =
               Enum.find(state.tools, &(&1["type"] == "function"))

      assert state.backend_tools == ["http_request"]
    end

    test "omits the engine when left on auto, rather than pinning OpenRouter's default", %{
      conn: conn
    } do
      params = %{
        "agent" => %{
          "provider" => "openrouter",
          "openrouter_model" => "openai/gpt-5.6-luna",
          "tools" => %{"web_search" => "true"},
          "web_search_engine" => "auto",
          "web_search_max_results" => ""
        }
      }

      conn = post(conn, ~p"/agent-chat", params)
      state = conversation_state(conn)

      assert state.tools == [%{"type" => "openrouter:web_search"}]
    end

    test "a typed slug beats the dropdown", %{conn: conn} do
      params = %{
        "agent" => %{
          "provider" => "openrouter",
          "openrouter_model" => "openai/gpt-5.6-luna",
          "openrouter_model_custom" => "anthropic/claude-something-new"
        }
      }

      conn = post(conn, ~p"/agent-chat", params)

      assert conversation_state(conn).model == "anthropic/claude-something-new"
    end

    test "says so plainly when no model was chosen, instead of failing at the first message", %{
      conn: conn
    } do
      params = %{"agent" => %{"provider" => "openrouter", "openrouter_model_custom" => ""}}

      html = conn |> post(~p"/agent-chat", params) |> html_response(200)

      assert html =~ "OpenRouter needs a model"
    end

    test "drops Gemini-only settings rather than sending ones OpenRouter ignores", %{conn: conn} do
      params = %{
        "agent" => %{
          "provider" => "openrouter",
          "openrouter_model" => "openai/gpt-5.6-luna",
          "thinking_enabled" => "true",
          "thinking_budget" => "1024",
          "response_modalities" => %{"text" => "true", "image" => "true"}
        }
      }

      conn = post(conn, ~p"/agent-chat", params)
      state = conversation_state(conn)

      assert state.thinking_enabled == false
      assert state.thinking_budget == nil
      assert state.response_modalities == nil
    end

    test "adds raw JSON tools on top of the ticked ones", %{conn: conn} do
      params = %{
        "agent" => %{
          "provider" => "openrouter",
          "openrouter_model" => "openai/gpt-5.6-luna",
          "tools" => %{"web_search" => "true"},
          "web_search_engine" => "auto",
          "openrouter_tools" => ~s({"type": "openrouter:web_fetch"})
        }
      }

      conn = post(conn, ~p"/agent-chat", params)
      state = conversation_state(conn)

      assert %{"type" => "openrouter:web_search"} in state.tools
      assert %{"type" => "openrouter:web_fetch"} in state.tools
    end

    test "rejects malformed raw JSON with a readable message", %{conn: conn} do
      params = %{
        "agent" => %{
          "provider" => "openrouter",
          "openrouter_model" => "openai/gpt-5.6-luna",
          "openrouter_tools" => "{not json"
        }
      }

      html = conn |> post(~p"/agent-chat", params) |> html_response(200)

      assert html =~ "tools JSON is invalid"
    end
  end

  defp conversation_state(conn) do
    id = conn |> redirected_to() |> String.split("/") |> List.last()
    assert [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :sys.get_state(pid)
  end
end
