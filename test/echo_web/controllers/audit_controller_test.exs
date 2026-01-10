defmodule EchoWeb.AuditControllerTest do
  use EchoWeb.ConnCase

  alias Echo.AuditSessions
  alias Echo.AuditEvents

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "create session" do
    test "renders session when data is valid", %{conn: conn} do
      params = %{
        "id" => "sess_123",
        "session_hash" => "hash_123",
        "system_prompt" => "You are a helpful assistant",
        "created_at" => ~U[2024-01-01 12:00:00Z]
      }

      conn = post(conn, ~p"/api/v1/audit/sessions", params)
      assert %{"id" => "sess_123"} = json_response(conn, 201)["data"]
    end
  end

  describe "create event" do
    setup do
      {:ok, session} =
        AuditSessions.save_session(%{
          id: "sess_123",
          session_hash: "hash_123",
          system_prompt: "prompt",
          created_at: ~U[2024-01-01 12:00:00Z]
        })

      %{session: session}
    end

    test "renders event when data is valid", %{conn: conn, session: session} do
      params = %{
        "id" => "evt_123",
        "session_id" => session.id,
        "type" => "function_call",
        "content" => "call tool",
        "payload" => %{"foo" => "bar"},
        "created_at" => ~U[2024-01-01 12:01:00Z]
      }

      conn = post(conn, ~p"/api/v1/audit/events", params)
      assert %{"id" => "evt_123"} = json_response(conn, 201)["data"]
    end
  end
end
