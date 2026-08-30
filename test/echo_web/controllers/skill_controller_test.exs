defmodule EchoWeb.SkillControllerTest do
  # async: false -- the shared test database, and FakeHTTPClient's global stub.
  use EchoWeb.ConnCase, async: false

  alias Echo.Agents.Providers.Gemini
  alias Echo.FakeHTTPClient
  alias Echo.Skills

  setup %{conn: conn} do
    FakeHTTPClient.reset()
    previous = Application.get_env(:echo, Gemini, [])

    Application.put_env(
      :echo,
      Gemini,
      Keyword.merge(previous, api_key: "test-key", http_client: FakeHTTPClient)
    )

    on_exit(fn ->
      Application.put_env(:echo, Gemini, previous)
      FakeHTTPClient.reset()
    end)

    {:ok, conn: conn |> authenticate() |> put_req_header("content-type", "application/json")}
  end

  defp data(conn, status \\ 200), do: json_response(conn, status)["data"]
  defp errors(conn, status), do: json_response(conn, status)["errors"]

  defp stub_reply(text) do
    FakeHTTPClient.stub(%{
      "candidates" => [
        %{"content" => %{"parts" => [%{"text" => text}]}, "finishReason" => "STOP"}
      ]
    })
  end

  describe "POST /api/v1/skills" do
    test "creates a skill", %{conn: conn} do
      slug = unique("skill")

      conn =
        post(conn, ~p"/api/v1/skills", %{
          "skill" => %{
            "slug" => slug,
            "name" => "Weekly",
            "tool_config" => %{"http_request" => %{"gate" => "mutations"}}
          }
        })

      body = data(conn, 201)
      assert body["slug"] == slug
      assert body["tool_config"] == %{"http_request" => %{"gate" => "mutations"}}
      assert body["created_at"]
    end

    test "a missing wrapper is a 400, not a crash", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/skills", %{"slug" => "x"})
      assert errors(conn, 400) == %{"skill" => ["is required"]}
    end

    test "an unknown tool is refused", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/skills", %{
          "skill" => %{
            "slug" => unique("skill"),
            "name" => "n",
            "tool_config" => %{"nope" => %{}}
          }
        })

      assert %{"tool_config" => [_]} = errors(conn, 422)
    end
  end

  describe "GET /api/v1/skills" do
    test "reachable by id and by slug", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))

      assert data(get(conn, ~p"/api/v1/skills/#{skill.slug}"))["id"] == skill.id
      assert data(get(conn, ~p"/api/v1/skills/#{skill.id}"))["id"] == skill.id
    end

    test "filters on enabled without assuming an empty table", %{conn: conn} do
      on = skill_fixture(slug: unique("skill"))
      off = skill_fixture(slug: unique("skill"), enabled: false)

      slugs = conn |> get(~p"/api/v1/skills?enabled=true") |> data() |> Enum.map(& &1["slug"])
      assert on.slug in slugs
      refute off.slug in slugs
    end

    test "an unknown slug is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/api/v1/skills/no-such-skill") end
    end
  end

  describe "PUT /api/v1/skills/:id" do
    test "renames, and ignores provider and instructions", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"), provider: "openrouter", instructions: "body")

      body =
        conn
        |> put(~p"/api/v1/skills/#{skill.id}", %{
          "skill" => %{"name" => "renamed", "provider" => "gemini", "instructions" => "sneaky"}
        })
        |> data()

      assert body["name"] == "renamed"
      assert body["provider"] == "openrouter"
      assert body["instructions"] == "body"
    end

    test "instructions have their own route", %{conn: conn} do
      skill = skill_fixture(instructions: "old")

      body =
        conn
        |> put(~p"/api/v1/skills/#{skill.id}/instructions", %{"instructions" => "new"})
        |> data()

      assert body["instructions"] == "new"
    end
  end

  describe "DELETE /api/v1/skills/:id" do
    test "removes the skill", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))

      assert response(delete(conn, ~p"/api/v1/skills/#{skill.id}"), 204)
      assert_error_sent 404, fn -> get(conn, ~p"/api/v1/skills/#{skill.slug}") end
    end
  end

  describe "variables" do
    test "declares, reports positions, and binds", %{conn: conn} do
      skill = skill_fixture()

      declared =
        conn
        |> put(~p"/api/v1/skills/#{skill.id}/variables", %{
          "variables" => [
            %{"name" => "repo", "kind" => "config", "required" => true},
            %{"name" => "token", "kind" => "secret"}
          ]
        })
        |> json_response(200)

      assert Enum.map(declared["data"], & &1["name"]) == ~w(repo token)
      assert declared["unbound"] == ["repo"]

      bound =
        conn
        |> put(~p"/api/v1/skills/#{skill.id}/variables/repo", %{
          "variable" => %{"value" => "echo-server"}
        })
        |> data()

      assert bound["value"] == "echo-server"
    end

    test "never renders a secret's value, only whether it has one", %{conn: conn} do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "token", kind: "secret"})

      body =
        conn
        |> put(~p"/api/v1/skills/#{skill.id}/variables/token", %{
          "variable" => %{"value" => "ghp_real"}
        })
        |> data()

      assert body["value"] == nil
      assert body["bound"] == true

      # And not through the listing either.
      listed = conn |> get(~p"/api/v1/skills/#{skill.id}/variables") |> data() |> hd()
      assert listed["value"] == nil
      assert listed["bound"] == true
    end

    test "a missing wrapper is a 400", %{conn: conn} do
      skill = skill_fixture()
      conn = put(conn, ~p"/api/v1/skills/#{skill.id}/variables", %{})
      assert errors(conn, 400) == %{"variables" => ["is required"]}
    end
  end

  describe "POST /api/v1/skills/:slug/run" do
    test "accepts with 202 and the run is readable", %{conn: conn} do
      stub_reply("done")
      skill = skill_fixture(slug: unique("skill"))

      queued = data(post(conn, ~p"/api/v1/skills/#{skill.slug}/run", %{"input" => %{}}), 202)
      assert queued["status"] == "queued"
      assert is_integer(queued["id"])

      finished = wait_for_terminal(queued["id"])
      assert finished.status == "succeeded"

      shown = data(get(conn, ~p"/api/v1/skills/#{skill.slug}/runs/#{queued["id"]}"))
      assert shown["status"] == "succeeded"
      assert shown["session_id"] == finished.session_id
    end

    test "refuses with 422 when a required variable is unbound, and starts nothing", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))
      variable_fixture(skill, %{name: "api_key", required: true})

      conn = post(conn, ~p"/api/v1/skills/#{skill.slug}/run", %{})

      assert %{"variables" => [message]} = errors(conn, 422)
      assert message =~ "api_key"
      assert Skills.list_runs(skill) == []
      assert FakeHTTPClient.requests() == []
    end

    test "input must be an object", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))

      conn = post(conn, ~p"/api/v1/skills/#{skill.slug}/run", %{"input" => "not a map"})
      assert %{"input" => [_]} = errors(conn, 422)
    end
  end

  describe "authentication" do
    test "every skills route rejects an anonymous caller" do
      skill = skill_fixture(slug: unique("skill"))
      conn = build_conn()

      assert json_response(get(conn, ~p"/api/v1/skills"), 401)
      assert json_response(post(conn, ~p"/api/v1/skills", %{}), 401)
      assert json_response(get(conn, ~p"/api/v1/skills/#{skill.id}"), 401)
      assert json_response(post(conn, ~p"/api/v1/skills/#{skill.slug}/run", %{}), 401)
      assert FakeHTTPClient.requests() == []
    end
  end

  defp wait_for_terminal(run_id, attempts \\ 100) do
    run = Skills.get_run!(run_id)

    cond do
      run.status in ~w(succeeded failed awaiting_approval) -> run
      attempts > 0 -> Process.sleep(10) && wait_for_terminal(run_id, attempts - 1)
      true -> flunk("run #{run_id} never reached a terminal status (#{run.status})")
    end
  end
end
