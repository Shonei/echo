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

  describe "the builder hand-off" do
    test "the skills page starts the builder through the agent form, pre-filled", %{conn: conn} do
      html = conn |> get(~p"/skills") |> html_response(200)
      assert html =~ "/agent-chat/new?preset=skill_builder"

      form = conn |> get(~p"/agent-chat/new?preset=skill_builder") |> html_response(200)

      # The prompt and its tools are filled in, so you see what you are starting.
      assert form =~ "turn a piece of repeatable work into a **skill**"
      assert form =~ ~s(name="agent[tools][create_skill]")
      assert form =~ "checked"
    end

    test "without a preset the form starts empty", %{conn: conn} do
      form = conn |> get(~p"/agent-chat/new") |> html_response(200)

      refute form =~ "turn a piece of repeatable work into a **skill**"
      assert form =~ "Start from a preset"
    end

    test "the skill tools are rendered from the registry, not hardcoded", %{conn: conn} do
      form = conn |> get(~p"/agent-chat/new") |> html_response(200)

      for name <- Echo.Agents.Tools.skill_management_names() do
        assert form =~ ~s(name="agent[tools][#{name}]"), "#{name} has no checkbox on the form"
      end
    end
  end
end
