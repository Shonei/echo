defmodule Echo.Agents.Tools.SkillAuthoringTest do
  use Echo.DataCase, async: true

  alias Echo.Agents.Tools
  alias Echo.Skills

  defp run(name, args), do: Tools.backend(name).run(args)

  describe "create_skill" do
    test "creates one and reports it back" do
      slug = unique("skill")

      result = run("create_skill", %{"slug" => slug, "name" => "Weekly", "instructions" => "Go."})

      assert result["slug"] == slug
      assert result["tools"] == []
      assert Skills.get_skill_by_slug(slug)
    end

    test "a rejected skill comes back as something the model can correct" do
      result = run("create_skill", %{"slug" => "Not A Slug", "name" => "n"})

      assert result["error"]
      assert result["details"]["slug"]
    end

    test "a duplicate slug is reported, not raised" do
      skill = skill_fixture(slug: unique("skill"))

      assert run("create_skill", %{"slug" => skill.slug, "name" => "n"})["details"]["slug"]
    end
  end

  describe "update_skill" do
    test "renames without touching the body" do
      skill = skill_fixture(slug: unique("skill"), instructions: "original")

      result = run("update_skill", %{"slug" => skill.slug, "name" => "renamed"})

      assert result["name"] == "renamed"
      assert result["instructions"] == "original"
    end

    test "an unknown slug is an error the model can read" do
      assert run("update_skill", %{"slug" => "no-such-skill"})["error"] =~ "no-such-skill"
    end
  end

  describe "update_skill_instructions" do
    test "replaces the body" do
      skill = skill_fixture(slug: unique("skill"), instructions: "old")

      result = run("update_skill_instructions", %{"slug" => skill.slug, "instructions" => "new"})

      assert result["instructions"] == "new"
    end
  end

  describe "define_skill_variables" do
    test "declares them and says which are waiting on an operator" do
      skill = skill_fixture(slug: unique("skill"))

      result =
        run("define_skill_variables", %{
          "slug" => skill.slug,
          "variables" => [
            %{"name" => "repo", "kind" => "config", "required" => true},
            %{"name" => "token", "kind" => "secret"}
          ]
        })

      assert Enum.map(result["variables"], & &1["name"]) == ~w(repo token)
      assert result["waiting_on_an_operator"] == ["repo"]
      refute Enum.any?(result["variables"], &Map.has_key?(&1, "value"))
    end

    test "a bad kind is reported rather than stored" do
      skill = skill_fixture(slug: unique("skill"))

      result =
        run("define_skill_variables", %{
          "slug" => skill.slug,
          "variables" => [%{"name" => "x", "kind" => "oauth"}]
        })

      assert result["details"]["kind"]
    end
  end

  describe "reads" do
    test "get_skill returns the body and the variables, never a value" do
      skill = skill_fixture(slug: unique("skill"), instructions: "body")
      variable_fixture(skill, %{name: "token", kind: "secret", value: "ghp_real"})

      result = run("get_skill", %{"slug" => skill.slug})

      assert result["instructions"] == "body"
      assert [%{"name" => "token", "has_value" => true}] = result["variables"]
      refute inspect(result) =~ "ghp_real"
    end

    test "list_skills finds this test's skill" do
      skill = skill_fixture(slug: unique("skill"))

      slugs = run("list_skills", %{})["skills"] |> Enum.map(& &1["slug"])
      assert skill.slug in slugs
    end
  end

  describe "the write boundary" do
    test "no authoring tool accepts a tool grant or a provider change" do
      skill = skill_fixture(slug: unique("skill"))

      run("update_skill", %{
        "slug" => skill.slug,
        "tool_config" => %{"http_request" => %{}},
        "provider" => "openrouter"
      })

      reloaded = Skills.get_skill_by_slug(skill.slug)
      assert reloaded.tool_config == %{}
      assert reloaded.provider == skill.provider
    end

    test "a skill cannot be granted a skill-writing tool" do
      assert {:error, changeset} =
               Skills.create_skill(%{
                 "slug" => unique("skill"),
                 "name" => "n",
                 "tool_config" => %{"create_skill" => %{}}
               })

      assert %{tool_config: [message]} = errors_on(changeset)
      assert message =~ "create_skill"
    end

    test "but an operator's own conversation can have them" do
      assert "create_skill" in Tools.names()
      refute "create_skill" in Tools.skill_grantable_names()
      assert "http_request" in Tools.skill_grantable_names()
    end
  end
end
