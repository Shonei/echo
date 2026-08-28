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

    test "a query narrows the list rather than returning everything" do
      wanted = skill_fixture(slug: unique("skill"), name: "Dependency auditor")
      other = skill_fixture(slug: unique("skill"), name: "Something unrelated")

      slugs = run("list_skills", %{"query" => "Dependency"})["skills"] |> Enum.map(& &1["slug"])
      assert wanted.slug in slugs
      refute other.slug in slugs

      # Substring, not word order.
      slugs =
        run("list_skills", %{"query" => "auditor depend"})["skills"] |> Enum.map(& &1["slug"])

      refute wanted.slug in slugs
      refute other.slug in slugs
    end

    test "a query matches the description too" do
      skill = skill_fixture(slug: unique("skill"), description: "Checks npm releases nightly")

      slugs = run("list_skills", %{"query" => "npm releases"})["skills"] |> Enum.map(& &1["slug"])
      assert skill.slug in slugs
    end

    test "wildcards in a query are matched literally" do
      skill = skill_fixture(slug: unique("skill"), name: "Plain name")

      slugs = run("list_skills", %{"query" => "%"})["skills"] |> Enum.map(& &1["slug"])
      refute skill.slug in slugs
    end
  end

  describe "the tool catalogue in the builder's prompt" do
    test "lists what a skill can be granted, and nothing it cannot" do
      catalogue = Echo.Skills.SkillTools.grantable_catalogue()
      names = Enum.map(catalogue, & &1.name)

      assert "http_request" in names
      assert "google_search" in names
      assert "openrouter:web_search" in names

      # The builder's own tools are not a skill's to have.
      refute "create_skill" in names
      refute "get_skill" in names
    end

    test "every entry says what the tool does" do
      for tool <- Echo.Skills.SkillTools.grantable_catalogue() do
        assert is_binary(tool.description) and tool.description != "",
               "#{tool.name} has no description for the catalogue"
      end
    end

    test "the prompt renders it, so a new tool cannot go undescribed" do
      prompt = Echo.Agents.Presets.skill_builder()["system_prompt"]

      refute prompt =~ "{{tool_catalogue}}"

      for tool <- Echo.Skills.SkillTools.grantable_catalogue() do
        assert prompt =~ tool.name, "#{tool.name} is missing from the builder's prompt"
      end
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

    test "no skill-management tool is grantable, reads included" do
      for name <- ~w(create_skill update_skill update_skill_instructions
                     define_skill_variables list_skills get_skill) do
        assert name in Tools.names(), "#{name} should be a registered tool"
        refute name in Tools.skill_grantable_names(), "#{name} must not be grantable to a skill"
      end

      assert "http_request" in Tools.skill_grantable_names()
    end
  end
end
