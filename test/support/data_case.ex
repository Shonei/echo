defmodule Echo.DataCase do
  @moduledoc """
  Setup for tests that touch the database.

  Tests commit to a long-lived `echo_test` database. Do not assume tables are
  empty. Seed unique columns (slugs, paths, names) with `unique/1`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Echo.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Echo.DataCase
    end
  end

  @doc """
  A unique seed token, e.g. `"post-13"`. Use this for any column that must not
  collide with rows left by earlier test runs.
  """
  def unique(prefix \\ "seed") when is_binary(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc "An all-digit unique string, for slugs that look like ids."
  def unique_digits, do: Integer.to_string(System.unique_integer([:positive]))

  @doc """
  A helper that transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
