defmodule Echo.Skills.Variable do
  use Ecto.Schema
  import Ecto.Changeset

  # Declared and given a value by two separate paths: an agent says what a skill
  # needs, an operator says what fills it. A variable belongs to the skill, so
  # one value is shared by every run of it.
  schema "skill_variables" do
    field :name, :string
    field :kind, :string
    field :type, :string, default: "string"
    field :description, :string
    field :required, :boolean, default: false
    field :position, :integer, default: 0

    # A `secret` holds its value here in plain text for now. Encrypting this
    # column is contained: only `Echo.Skills.Variables` reads it.
    field :value, :string

    belongs_to :skill, Echo.Skills.Skill

    timestamps(type: :utc_datetime)
  end

  # A `secret` is scrubbed out of tool results and never rendered by the API;
  # a `config` is not. No `input` kind: a run's own text goes into the prompt.
  @kinds ~w(config secret)
  @types ~w(string number boolean)

  @doc """
  What a skill needs. This is what an agent's tool reaches.

  Does not cast `value`: an agent declaring what a skill needs must not be able
  to say what fills it. "The agent never learns the value exists" is a stronger
  property than "the agent proposes and a human checks".
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

  Encrypting `value` later is a change to this function and to
  `Echo.Skills.Variables`, and to nothing else.
  """
  def binding_changeset(variable, attrs) do
    variable
    |> cast(attrs, [:value])
    |> validate_value_matches_type()
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
