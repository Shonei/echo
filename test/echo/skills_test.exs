defmodule Echo.SkillsTest do
  use Echo.DataCase, async: true

  alias Echo.Skills
  alias Echo.Skills.Skill

  describe "create_skill/1" do
    test "stores names, tools and provider" do
      slug = unique("skill")

      assert {:ok, %Skill{} = skill} =
               Skills.create_skill(%{
                 "slug" => slug,
                 "name" => "Weekly report",
                 "tools" => ["http_request"],
                 "provider" => "openrouter"
               })

      assert skill.slug == slug
      assert skill.tools == ["http_request"]
      assert skill.provider == "openrouter"
      assert skill.enabled
    end

    test "a nil provider is the default, not an error" do
      assert {:ok, %Skill{provider: nil}} =
               Skills.create_skill(%{"slug" => unique("skill"), "name" => "n"})
    end

    test "rejects a duplicate slug" do
      slug = unique("skill")
      skill_fixture(slug: slug)

      assert {:error, changeset} = Skills.create_skill(%{"slug" => slug, "name" => "n"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects a slug that would not route" do
      for bad <- ["Not A Slug", "-lead", "double--dash", "trail-"] do
        assert {:error, changeset} = Skills.create_skill(%{"slug" => bad, "name" => "n"})
        assert %{slug: _} = errors_on(changeset)
      end
    end

    test "rejects a tool that is not registered" do
      assert {:error, changeset} =
               Skills.create_skill(%{
                 "slug" => unique("skill"),
                 "name" => "n",
                 "tools" => ["http_request", "definitely_not_a_tool"]
               })

      assert %{tools: [message]} = errors_on(changeset)
      assert message =~ "definitely_not_a_tool"
    end

    test "rejects a built-in the skill's provider does not offer" do
      assert {:error, changeset} =
               Skills.create_skill(%{
                 "slug" => unique("skill"),
                 "name" => "n",
                 "provider" => "openrouter",
                 "tools" => ["google_search"]
               })

      assert %{tools: [message]} = errors_on(changeset)
      assert message =~ "google_search"
    end

    test "accepts a built-in the skill's provider does offer" do
      assert {:ok, skill} =
               Skills.create_skill(%{
                 "slug" => unique("skill"),
                 "name" => "n",
                 "provider" => "openrouter",
                 "tools" => ["openrouter:web_search", "http_request"]
               })

      assert "openrouter:web_search" in skill.tools
    end

    test "rejects an unknown provider" do
      assert {:error, changeset} =
               Skills.create_skill(%{
                 "slug" => unique("skill"),
                 "name" => "n",
                 "provider" => "hal9000"
               })

      assert %{provider: _} = errors_on(changeset)
    end
  end

  describe "update_skill/2" do
    test "ignores a provider key, so the provider is fixed at creation" do
      skill = skill_fixture(slug: unique("skill"), provider: "openrouter")

      assert {:ok, updated} =
               Skills.update_skill(skill, %{"provider" => "gemini", "name" => "renamed"})

      assert updated.provider == "openrouter"
      assert updated.name == "renamed"
    end

    test "ignores an instructions key, so the body has one writer" do
      skill = skill_fixture(instructions: "original")

      assert {:ok, updated} =
               Skills.update_skill(skill, %{"instructions" => "sneaky", "name" => "renamed"})

      assert updated.instructions == "original"

      assert {:ok, rewritten} = Skills.update_skill_instructions(updated, "deliberate")
      assert rewritten.instructions == "deliberate"
    end

    test "validates tools against the provider already on the row" do
      skill = skill_fixture(slug: unique("skill"), provider: "openrouter")

      assert {:error, changeset} = Skills.update_skill(skill, %{"tools" => ["google_search"]})
      assert %{tools: _} = errors_on(changeset)
    end
  end

  describe "list_skills/1 and lookups" do
    test "filters on enabled without assuming the table is empty" do
      on = skill_fixture(slug: unique("skill"))
      off = skill_fixture(slug: unique("skill"), enabled: false)

      enabled = Skills.list_skills(%{enabled: true}) |> Enum.map(& &1.slug)
      assert on.slug in enabled
      refute off.slug in enabled
    end

    test "reachable by id and by slug" do
      skill = skill_fixture(slug: unique("skill"))

      assert Skills.get_skill_by_id_or_slug!(to_string(skill.id)).id == skill.id
      assert Skills.get_skill_by_id_or_slug!(skill.slug).id == skill.id
    end

    test "an all-digit slug stays reachable by slug" do
      slug = unique_digits()
      skill = skill_fixture(slug: slug)

      assert Skills.get_skill_by_id_or_slug!(slug).id == skill.id
    end
  end

  describe "delete_skill/1" do
    test "takes the skill's runs and variables with it" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo", value: "echo"})
      run = run_fixture(skill)

      assert {:ok, _} = Skills.delete_skill(skill)
      assert Skills.get_run(run.id) == nil
      assert Repo.all(from v in Skills.Variable, where: v.skill_id == ^skill.id) == []
    end
  end
end
