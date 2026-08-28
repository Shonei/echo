defmodule EchoWeb.SkillUIControllerTest do
  use EchoWeb.ConnCase, async: false

  alias Echo.Skills

  setup %{conn: conn} do
    auth = Application.get_env(:echo, :auth) || []
    user = Keyword.get(auth, :username, "test")
    pass = Keyword.get(auth, :password, "test")

    Application.put_env(:echo, :auth, username: user, password: pass)
    on_exit(fn -> Application.put_env(:echo, :auth, auth) end)

    credentials = Base.encode64("#{user}:#{pass}")
    {:ok, conn: put_req_header(conn, "authorization", "Basic #{credentials}")}
  end

  describe "GET /skills" do
    test "lists this test's skill", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"), name: "Weekly report")

      html = conn |> get(~p"/skills") |> html_response(200)
      assert html =~ "Weekly report"
      assert html =~ skill.slug
    end

    test "rejects an anonymous caller" do
      assert build_conn() |> get(~p"/skills") |> response(401)
    end
  end

  describe "GET /skills/:id" do
    test "shows instructions, variables and tool grants", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"), instructions: "Fetch the releases.")
      variable_fixture(skill, %{name: "repo_name", description: "which repo"})

      html = conn |> get(~p"/skills/#{skill.id}") |> html_response(200)

      assert html =~ "Fetch the releases."
      assert html =~ "$.repo_name"
      assert html =~ "which repo"
      assert html =~ "http_request"
    end

    test "never offers a skill-writing tool as grantable", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))

      html = conn |> get(~p"/skills/#{skill.id}") |> html_response(200)

      refute html =~ "create_skill"
      refute html =~ "define_skill_variables"
    end

    test "does not render a secret's value", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))
      variable_fixture(skill, %{name: "token", kind: "secret", value: "ghp_real"})

      html = conn |> get(~p"/skills/#{skill.id}") |> html_response(200)

      assert html =~ "$.token"
      refute html =~ "ghp_real"
    end
  end

  describe "POST /skills/:id/variables/:name" do
    test "saves a value", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))
      variable_fixture(skill, %{name: "repo_name"})

      conn = post(conn, ~p"/skills/#{skill.id}/variables/repo_name", %{"value" => "echo-server"})

      assert redirected_to(conn) == ~p"/skills/#{skill.id}"
      assert [%{value: "echo-server"}] = Skills.list_variables(skill)
    end

    test "a blank value clears it rather than storing an empty string", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))
      variable_fixture(skill, %{name: "repo_name", value: "old"})

      post(conn, ~p"/skills/#{skill.id}/variables/repo_name", %{"value" => "   "})

      assert [%{value: nil}] = Skills.list_variables(skill)
    end
  end

  describe "POST /skills/:id/tools" do
    test "grants the ticked tools with their gate", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))

      conn =
        post(conn, ~p"/skills/#{skill.id}/tools", %{
          "tools" => %{"http_request" => %{"granted" => "true", "gate" => "mutations"}}
        })

      assert redirected_to(conn) == ~p"/skills/#{skill.id}"

      assert Skills.get_skill!(skill.id).tool_config == %{
               "http_request" => %{"gate" => "mutations"}
             }
    end

    test "an unticked tool is removed", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"), tool_config: %{"http_request" => %{}})

      post(conn, ~p"/skills/#{skill.id}/tools", %{
        "tools" => %{"http_request" => %{"gate" => "never"}}
      })

      assert Skills.get_skill!(skill.id).tool_config == %{}
    end
  end

  describe "POST /skills/:id/run" do
    test "refuses and says which value is missing", %{conn: conn} do
      skill = skill_fixture(slug: unique("skill"))
      variable_fixture(skill, %{name: "api_key", kind: "secret", required: true})

      conn = post(conn, ~p"/skills/#{skill.id}/run", %{})

      assert redirected_to(conn) == ~p"/skills/#{skill.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "api_key"
      assert Skills.list_runs(skill) == []
    end
  end

  describe "POST /skills/builder" do
    test "starts a builder conversation and hands it to the agent chat", %{conn: conn} do
      conn = post(conn, ~p"/skills/builder", %{})

      assert path = redirected_to(conn)
      assert path =~ "/agent-chat/"

      session_id = path |> String.split("/") |> List.last()
      record = Echo.Agent.get_conversation(session_id)

      assert record.system_prompt =~ "turn a piece of repeatable work into a **skill**"
      assert [%{"functionDeclarations" => declarations}] = record.tools
      assert Enum.any?(declarations, &(&1["name"] == "create_skill"))
    end
  end
end
