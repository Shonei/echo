defmodule EchoWeb.AgentChatControllerTest do
  use EchoWeb.ConnCase, async: false

  setup %{conn: conn} do
    Application.put_env(:echo, :auth, username: "agent", password: "secret")
    on_exit(fn -> Application.delete_env(:echo, :auth) end)

    conn =
      put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("agent", "secret"))

    {:ok, conn: conn}
  end

  describe "new" do
    test "offers every option the conversation API supports", %{conn: conn} do
      html = conn |> get(~p"/agent-chat/new") |> html_response(200)

      for field <- [
            "agent[model]",
            "agent[system_prompt]",
            "agent[temperature]",
            "agent[max_output_tokens]",
            "agent[thinking_enabled]",
            "agent[thinking_budget]",
            "agent[response_modalities][image]",
            "agent[tools][google_search]",
            "agent[tools][url_context]",
            "agent[tools][http_request]"
          ] do
        assert html =~ field, "expected the form to expose #{field}"
      end
    end
  end

  describe "create" do
    test "wires the selected options into the conversation", %{conn: conn} do
      params = %{
        "agent" => %{
          "model" => "gemini-2.5-flash",
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

      assert state.model == "gemini-2.5-flash"
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
          "model" => "gemini-2.5-flash",
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

  defp conversation_state(conn) do
    id = conn |> redirected_to() |> String.split("/") |> List.last()
    assert [{pid, _}] = Registry.lookup(Echo.Agents.ConversationRegistry, id)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :sys.get_state(pid)
  end
end
