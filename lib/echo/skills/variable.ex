defmodule Echo.Skills.Variable do
  use Ecto.Schema
  import Ecto.Changeset

  # Declaration and binding, written by two paths that are deliberately
  # different privileges. The builder agent (Phase 3) declares what a skill
  # *needs*; only an operator says what fills it. A tool that could do both
  # could point a skill at any secret in the store.
  schema "skill_variables" do
    field :name, :string
    field :kind, :string
    field :type, :string, default: "string"
    field :description, :string
    field :required, :boolean, default: false
    field :position, :integer, default: 0
    field :oauth_provider, :string

    # Bindings. secret_id/connection_id are plain integers until Phases 6/7.
    field :secret_id, :id
    field :connection_id, :id
    field :value, :string

    belongs_to :skill, Echo.Skills.Skill

    timestamps(type: :utc_datetime)
  end

  # `secret` and `oauth` are in designs/skills.md and deliberately not accepted
  # yet: there is no secrets table (Phase 6) and no oauth_connections (Phase 7),
  # so such a row could only ever be unbound. Rejecting it here is what lets the
  # resolver stay total.
  @kinds ~w(config input)
  @types ~w(string number boolean)

  @doc """
  What a skill needs. Reachable by the builder agent in Phase 3.

  Casts neither `value`, `secret_id` nor `connection_id`: "the agent never
  learns secret ids exist" is a stronger property than "the agent proposes and
  a human checks".
  """
  def declaration_changeset(variable, attrs) do
    variable
    |> cast(attrs, [:name, :kind, :type, :description, :required, :position])
    |> validate_required([:name, :kind])
    |> validate_format(:name, ~r/^[a-z_][a-z0-9_]*$/,
      message: "must be lowercase letters, digits and underscores, starting with a letter or _"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:name, name: :skill_variables_skill_id_name_index)
    |> foreign_key_constraint(:skill_id)
  end

  @doc """
  What actually fills it. Operator API and UI only; no agent tool calls this.

  Phase 6 adds `:secret_id` to the cast list and nothing else changes.
  """
  def binding_changeset(variable, attrs) do
    variable
    |> cast(attrs, [:value])
    |> validate_bindable()
    |> validate_value_matches_type()
  end

  # An `input` variable's value arrives per run in `skill_runs.input`, so
  # binding one is a category error rather than a no-op. Say so, instead of
  # storing a value that will never be read.
  defp validate_bindable(changeset) do
    case get_field(changeset, :kind) do
      "config" -> changeset
      nil -> changeset
      kind -> add_error(changeset, :value, "cannot be bound on a #{kind} variable")
    end
  end

  # Values are stored as text whatever the declared type, so the parse has to
  # happen somewhere. Doing it here means the resolver, which runs on every
  # single run, can be total and never has to report a malformed literal.
  defp validate_value_matches_type(changeset) do
    case {get_field(changeset, :type), get_change(changeset, :value)} do
      {_type, nil} -> changeset
      {"number", value} -> validate_number_literal(changeset, value)
      {"boolean", value} -> validate_boolean_literal(changeset, value)
      {_string, _value} -> changeset
    end
  end

  defp validate_number_literal(changeset, value) do
    case {Integer.parse(value), Float.parse(value)} do
      {{_int, ""}, _} -> changeset
      {_, {_float, ""}} -> changeset
      _ -> add_error(changeset, :value, "is not a number")
    end
  end

  defp validate_boolean_literal(changeset, value) when value in ~w(true false), do: changeset

  defp validate_boolean_literal(changeset, _value),
    do: add_error(changeset, :value, ~s(must be "true" or "false"))

  def kinds, do: @kinds
  def types, do: @types
end
