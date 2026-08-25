defmodule Echo.Agents.ProvidersTest do
  use ExUnit.Case, async: true

  alias Echo.Agents.Providers

  describe "resolve/1" do
    test "nil means the default, which keeps existing callers on Gemini" do
      assert Providers.resolve(nil) == {:ok, Providers.Gemini}
      assert Providers.default() == Providers.Gemini
    end

    test "resolves every name it advertises, onto a module implementing the contract" do
      for name <- Providers.names() do
        assert {:ok, module} = Providers.resolve(name)

        # `function_exported?/3` answers for loaded modules only, and nothing
        # here has necessarily called into the provider yet.
        Code.ensure_loaded!(module)

        behaviours =
          module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert Echo.Agents.Provider in behaviours
        assert function_exported?(module, :generate_content, 2)
        assert function_exported?(module, :build_function_tools, 1)
      end
    end

    test "refuses a name it doesn't know rather than falling back" do
      assert Providers.resolve("hal9000") == {:error, {:unknown_provider, "hal9000"}}
      assert Providers.resolve(:gemini) == {:error, {:unknown_provider, :gemini}}
    end
  end
end
