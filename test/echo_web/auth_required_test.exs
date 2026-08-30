defmodule EchoWeb.AuthRequiredTest do
  @moduledoc """
  Locks the routes that can spend money (Gemini, S3) or write data behind auth.

  Two checks: the router actually pipes them through `:api_auth` / `:basic_auth`,
  and an anonymous (or garbage-token) request is halted with 401 before the
  controller runs.
  """
  use EchoWeb.ConnCase, async: false

  @bearer_calls [
    {:get, "/api/v1/assets"},
    {:post, "/api/v1/blogs"},
    {:put, "/api/v1/blogs/0"},
    {:delete, "/api/v1/blogs/0"},
    {:put, "/api/v1/blogs/0/content"},
    {:get, "/api/v1/blogs/0/revisions"},
    {:post, "/api/v1/ai/conversation"},
    {:delete, "/api/v1/ai/conversation/missing"},
    {:put, "/api/v1/ai/conversation/missing/message"},
    {:put, "/api/v1/ai/conversation/missing/content"},
    {:post, "/api/v1/ai/agents/editor"},
    {:post, "/api/v1/ai/agents/photographer"},
    {:post, "/api/v1/ai/agents/skill_builder"},
    {:put, "/api/v1/assets/auth-check.txt"},
    {:delete, "/api/v1/assets/auth-check.txt"},
    {:get, "/api/v1/skills"},
    {:post, "/api/v1/skills"},
    {:get, "/api/v1/skills/0"},
    {:put, "/api/v1/skills/0"},
    # `resources` generates PATCH alongside PUT for :update.
    {:patch, "/api/v1/skills/0"},
    {:delete, "/api/v1/skills/0"},
    {:put, "/api/v1/skills/0/instructions"},
    {:post, "/api/v1/skills/0/run"},
    {:get, "/api/v1/skills/0/runs"},
    {:get, "/api/v1/skills/0/runs/0"},
    {:get, "/api/v1/skills/0/variables"},
    {:put, "/api/v1/skills/0/variables"},
    {:put, "/api/v1/skills/0/variables/token"}
  ]

  # Prefixes where every route must have a 401 example. /api/v1/ai and
  # /api/v1/skills both reach a model; skills also writes rows that carry tool
  # grants, which is a bigger deal than the money.
  @guarded_prefixes ["/api/v1/ai", "/api/v1/skills"]

  describe "401 table covers wallet routes" do
    test "every route behind a guarded prefix has a 401 example" do
      guarded =
        Enum.filter(routes(), fn route ->
          Enum.any?(@guarded_prefixes, &String.starts_with?(route.path, &1))
        end)

      assert guarded != []

      for route <- guarded do
        assert Enum.any?(@bearer_calls, fn {verb, path} ->
                 verb == route.verb and matches_template?(route.path, path)
               end),
               "#{route.verb} #{route.path} can call a model or grant tools. " <>
                 "Add it to @bearer_calls."
      end
    end

    test "asset PUT and DELETE have a 401 example" do
      matched =
        Enum.filter(routes(), fn route ->
          route.path == "/api/v1/assets/*path" and route.verb in [:put, :delete]
        end)

      assert matched != []

      for route <- matched do
        assert Enum.any?(@bearer_calls, fn {verb, path} ->
                 verb == route.verb and String.starts_with?(path, "/api/v1/assets/")
               end),
               "#{route.verb} #{route.path} writes to S3. Add it to @bearer_calls."
      end
    end

    test "GET /api/v1/assets has a 401 example" do
      assert {:get, "/api/v1/assets"} in @bearer_calls
    end
  end

  describe "anonymous callers cannot spend money or write" do
    for {verb, path} <- @bearer_calls do
      test "#{verb} #{path} returns 401 without a valid token", %{conn: conn} do
        anonymous = dispatch_verb(conn, unquote(verb), unquote(path))
        assert anonymous.status == 401

        forged =
          conn
          |> put_req_header("authorization", "Bearer not-a-real-token")
          |> dispatch_verb(unquote(verb), unquote(path))

        assert forged.status == 401
      end
    end
  end

  describe "PUT /api/agent-chat/:id/content" do
    setup do
      previous = Application.get_env(:echo, :auth)

      Application.put_env(:echo, :auth,
        username: "agent",
        password: "secret",
        secret: "test-secret"
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:echo, :auth, previous)
        else
          Application.delete_env(:echo, :auth)
        end
      end)

      :ok
    end

    test "rejects anonymous callers before Gemini", %{conn: conn} do
      conn =
        put(conn, "/api/agent-chat/missing/content", %{
          "content_blocks" => [%{"text" => "hi"}]
        })

      assert conn.status == 401
    end

    test "rejects a wrong password before Gemini", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("agent", "wrong"))
        |> put("/api/agent-chat/missing/content", %{"content_blocks" => [%{"text" => "hi"}]})

      assert conn.status == 401
    end

    test "a valid basic-auth caller reaches the controller", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("agent", "secret"))
        |> put("/api/agent-chat/missing/content", %{"content_blocks" => [%{"text" => "hi"}]})

      # Conversation does not exist; 404 means auth passed and Gemini was not called.
      assert json_response(conn, 404)
    end
  end

  defp routes, do: EchoWeb.Router.__routes__()

  defp matches_template?(template, path) do
    source =
      template
      |> Regex.escape()
      |> String.replace(~r/:[A-Za-z0-9_]+/, "[^/]+")
      |> String.replace(~r/\\\*[A-Za-z0-9_]+/, ".+")

    Regex.match?(Regex.compile!("^#{source}$"), path)
  end

  defp dispatch_verb(conn, :get, path), do: get(conn, path)
  defp dispatch_verb(conn, :post, path), do: post(conn, path, %{})
  defp dispatch_verb(conn, :put, path), do: put(conn, path, %{})
  defp dispatch_verb(conn, :patch, path), do: patch(conn, path, %{})
  defp dispatch_verb(conn, :delete, path), do: delete(conn, path)
end
