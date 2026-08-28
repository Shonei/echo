defmodule Echo.Skills.VariablesTest do
  use Echo.DataCase, async: true

  alias Echo.Skills
  alias Echo.Skills.Variables

  describe "define_variables/2" do
    test "positions come from list order" do
      skill = skill_fixture()

      assert {:ok, result} =
               Skills.define_variables(skill, [
                 %{"name" => "first", "kind" => "config"},
                 %{"name" => "second", "kind" => "input"},
                 %{"name" => "third", "kind" => "config"}
               ])

      assert Enum.map(result.variables, & &1.name) == ~w(first second third)
      assert Enum.map(result.variables, & &1.position) == [0, 1, 2]
    end

    test "rejects a name that could not be written as a placeholder" do
      skill = skill_fixture()

      for bad <- ["Repo Name", "9lives", "has-dash"] do
        assert {:error, changeset} =
                 Skills.define_variables(skill, [%{"name" => bad, "kind" => "config"}])

        assert %{name: _} = errors_on(changeset)
      end
    end

    test "rejects kinds whose store does not exist yet" do
      skill = skill_fixture()

      for kind <- ~w(secret oauth) do
        assert {:error, changeset} =
                 Skills.define_variables(skill, [%{"name" => "token", "kind" => kind}])

        assert %{kind: _} = errors_on(changeset)
      end
    end

    test "keeps a binding whose variable survives, drops one whose does not" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "kept", value: "keepme"})
      variable_fixture(skill, %{name: "gone", value: "dropme"})

      assert {:ok, result} =
               Skills.define_variables(skill, [
                 %{"name" => "kept", "kind" => "config"},
                 %{"name" => "fresh", "kind" => "config"}
               ])

      assert result.dropped_bindings == ["gone"]

      by_name = Map.new(result.variables, &{&1.name, &1})
      assert by_name["kept"].value == "keepme"
      assert by_name["fresh"].value == nil
      refute Map.has_key?(by_name, "gone")
    end

    test "changing a variable's kind clears its binding" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "thing", value: "literal"})

      assert {:ok, result} =
               Skills.define_variables(skill, [%{"name" => "thing", "kind" => "input"}])

      assert [variable] = result.variables
      assert variable.kind == "input"
      assert variable.value == nil
    end

    test "reports required variables that nothing has filled" do
      skill = skill_fixture()

      assert {:ok, result} =
               Skills.define_variables(skill, [
                 %{"name" => "needed", "kind" => "config", "required" => true},
                 %{"name" => "optional", "kind" => "config"}
               ])

      assert result.unbound == ["needed"]
    end
  end

  describe "bind_variable/3" do
    test "binds a config literal" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo"})

      assert {:ok, variable} = Skills.bind_variable(skill, "repo", %{"value" => "echo-server"})
      assert variable.value == "echo-server"
    end

    test "refuses an input variable, whose value arrives per run" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "issue", kind: "input"})

      assert {:error, changeset} = Skills.bind_variable(skill, "issue", %{"value" => "12"})
      assert %{value: [message]} = errors_on(changeset)
      assert message =~ "input"
    end

    test "checks the literal against the declared type" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "retries", type: "number"})

      assert {:error, changeset} = Skills.bind_variable(skill, "retries", %{"value" => "abc"})
      assert %{value: ["is not a number"]} = errors_on(changeset)

      assert {:ok, variable} = Skills.bind_variable(skill, "retries", %{"value" => "10"})
      assert variable.value == "10"
    end

    test "is not found for a variable the skill never declared" do
      skill = skill_fixture()
      assert {:error, :not_found} = Skills.bind_variable(skill, "nope", %{"value" => "x"})
    end
  end

  describe "check_required/2" do
    test "passes when every required variable is filled" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo", required: true, value: "echo"})
      variable_fixture(skill, %{name: "issue", kind: "input", required: true})

      skill = Repo.preload(skill, :variables, force: true)
      assert :ok = Variables.check_required(skill, %{"issue" => 42})
    end

    test "names every missing one, not just the first" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo", required: true})
      variable_fixture(skill, %{name: "issue", kind: "input", required: true})

      skill = Repo.preload(skill, :variables, force: true)

      assert {:error, {:unbound_variables, missing}} = Variables.check_required(skill, %{})
      assert Enum.sort(missing) == ~w(issue repo)
    end

    test "ignores an unbound optional variable" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "note"})

      skill = Repo.preload(skill, :variables, force: true)
      assert :ok = Variables.check_required(skill, %{})
    end
  end

  describe "fetch/2" do
    test "reads config from the skill and input from the run" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo", value: "echo-server"})
      variable_fixture(skill, %{name: "issue", kind: "input", type: "number"})
      run = run_fixture(skill, %{"input" => %{"issue" => 42}})

      assert {:ok, resolved} = Variables.fetch(Variables.scope(run), ~w(repo issue))

      assert resolved == %{
               "repo" => {"echo-server", :plain},
               "issue" => {42, :plain}
             }
    end

    test "casts a config literal to its declared type" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "retries", type: "number", value: "10"})
      variable_fixture(skill, %{name: "verbose", type: "boolean", value: "true"})
      run = run_fixture(skill)

      assert {:ok, resolved} = Variables.fetch(Variables.scope(run), ~w(retries verbose))
      assert resolved["retries"] == {10, :plain}
      assert resolved["verbose"] == {true, :plain}
    end

    test "omits a declared variable that nothing has bound" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "unset"})
      run = run_fixture(skill)

      assert {:ok, %{}} == Variables.fetch(Variables.scope(run), ["unset"])
    end

    test "a scope it cannot answer is an error, not an empty map" do
      assert {:error, {:unknown_scope, _}} = Variables.fetch("skill_run:0", ["x"])
      assert {:error, {:unknown_scope, _}} = Variables.fetch("nonsense", ["x"])
    end
  end
end
