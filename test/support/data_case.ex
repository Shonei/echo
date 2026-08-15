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
  A unique seed token, e.g. `"post-550e8400-e29b-41d4-a716-446655440000"`.

  Use this for any column that must not collide with rows left by earlier runs.
  `System.unique_integer/1` only stays unique for one BEAM lifetime, so it
  repeats after `mix test` restarts and collides with leftover CI rows.
  """
  def unique(prefix \\ "seed") when is_binary(prefix) do
    "#{prefix}-#{Ecto.UUID.generate()}"
  end

  @doc """
  An all-digit unique string, for slugs that look like ids.

  Must fit in a Postgres `bigint`: `get_blog_by_id_or_slug!/1` tries the value
  as an id first, and a 128-bit number overflows that encode.
  """
  def unique_digits do
    <<n::63, _::1>> = :crypto.strong_rand_bytes(8)
    Integer.to_string(max(n, 1))
  end

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
