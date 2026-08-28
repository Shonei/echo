defmodule Echo.StubVariableResolver do
  @moduledoc """
  A stand-in for `Echo.Skills.Variables` in conversation tests.

  Phase 1 resolves every real variable as `:plain`, so nothing is ever scrubbed
  out of a tool result in production. This stub can mark a value `:sensitive`,
  which is what lets the scrub path be exercised end to end before Phase 6
  exists to produce a real secret.

  Bindings live in the application environment rather than the process
  dictionary, because the process that sets them (the test) is not the one that
  reads them (a `Echo.Agents.ConversationServer`). **Tests using this must be
  `async: false`.**
  """

  @behaviour Echo.Agents.VariableResolver

  @key :stub_variable_resolver_bindings

  @doc """
  Sets the bindings for `scope`, as `%{name => {value, :plain | :sensitive}}`.
  """
  def put(scope, bindings) do
    Application.put_env(:echo, @key, Map.put(all(), scope, bindings))
    :ok
  end

  @doc """
  Clears every binding. Call in `setup`.
  """
  def reset, do: Application.delete_env(:echo, @key)

  defp all, do: Application.get_env(:echo, @key, %{})

  @impl true
  def fetch(scope, names) do
    case Map.fetch(all(), scope) do
      {:ok, bindings} -> {:ok, Map.take(bindings, names)}
      :error -> {:error, {:unknown_scope, scope}}
    end
  end
end
