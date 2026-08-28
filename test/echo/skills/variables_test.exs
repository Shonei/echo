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
                 %{"name" => "second", "kind" => "secret"},
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

    test "rejects a kind that is not config or secret" do
      skill = skill_fixture()

      for kind <- ~w(oauth input nonsense) do
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

    test "redeclaring a secret as config clears the value, so it cannot be exposed" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "token", kind: "secret", value: "ghp_real"})

      assert {:ok, result} =
               Skills.define_variables(skill, [%{"name" => "token", "kind" => "config"}])

      assert [variable] = result.variables
      assert variable.kind == "config"
      assert variable.value == nil
    end

    test "promoting a config to a secret keeps the value, which only adds protection" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "token", value: "already-here"})

      assert {:ok, result} =
               Skills.define_variables(skill, [%{"name" => "token", "kind" => "secret"}])

      assert [variable] = result.variables
      assert variable.value == "already-here"
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

    test "gives a secret its value the same way" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "token", kind: "secret"})

      assert {:ok, variable} = Skills.bind_variable(skill, "token", %{"value" => "ghp_real"})
      assert variable.value == "ghp_real"
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

  describe "check_required/1" do
    test "passes when every required variable has a value" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo", required: true, value: "echo"})
      variable_fixture(skill, %{name: "token", kind: "secret", required: true, value: "k"})

      skill = Repo.preload(skill, :variables, force: true)
      assert :ok = Variables.check_required(skill)
    end

    test "names every missing one, not just the first" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo", required: true})
      variable_fixture(skill, %{name: "token", kind: "secret", required: true})

      skill = Repo.preload(skill, :variables, force: true)

      assert {:error, {:unbound_variables, missing}} = Variables.check_required(skill)
      assert Enum.sort(missing) == ~w(repo token)
    end

    test "ignores an optional variable with no value" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "note"})

      skill = Repo.preload(skill, :variables, force: true)
      assert :ok = Variables.check_required(skill)
    end
  end

  describe "fetch/2" do
    test "reads values off the skill, marking secrets sensitive" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "repo", value: "echo-server"})
      variable_fixture(skill, %{name: "token", kind: "secret", value: "ghp_real"})

      assert {:ok, resolved} = Variables.fetch(Variables.scope(skill), ~w(repo token))

      assert resolved == %{
               "repo" => {"echo-server", :plain},
               "token" => {"ghp_real", :sensitive}
             }
    end

    test "casts a literal to its declared type" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "retries", type: "number", value: "10"})
      variable_fixture(skill, %{name: "verbose", type: "boolean", value: "true"})

      assert {:ok, resolved} = Variables.fetch(Variables.scope(skill), ~w(retries verbose))
      assert resolved["retries"] == {10, :plain}
      assert resolved["verbose"] == {true, :plain}
    end

    test "omits a declared variable with no value" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "unset"})

      assert {:ok, %{}} == Variables.fetch(Variables.scope(skill), ["unset"])
    end

    test "a scope it cannot answer is an error, not an empty map" do
      assert {:error, {:unknown_scope, _}} = Variables.fetch("nonsense", ["x"])
      assert {:error, {:unknown_scope, _}} = Variables.fetch("skill:abc", ["x"])
      # A skill that no longer exists resolves nothing rather than erroring:
      # every name is simply absent, which the model is told about.
      assert {:ok, %{}} == Variables.fetch("skill:0", ["x"])
    end
  end
end
