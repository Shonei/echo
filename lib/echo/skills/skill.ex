defmodule Echo.Skills.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  alias Echo.Agents.Providers
  alias Echo.Skills.SkillTools

  # A skill is a preset that lives in a row: markdown instructions, the tool
  # names it may use, and generation config. Unlike `Echo.Agents.Presets`,
  # adding one is not a deploy.
  schema "skills" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :instructions, :string
    field :tool_config, :map, default: %{}
    field :provider, :string
    field :model, :string
    field :temperature, :float
    field :max_output_tokens, :integer
    field :enabled, :boolean, default: true

    has_many :variables, Echo.Skills.Variable, preload_order: [asc: :position]
    has_many :runs, Echo.Skills.Run

    timestamps(type: :utc_datetime)
  end

  @metadata_fields [
    :slug,
    :name,
    :description,
    :tool_config,
    :model,
    :temperature,
    :max_output_tokens,
    :enabled
  ]

  @gates ~w(never mutations always)

  @doc """
  Casts everything, including `provider` and `instructions`.

  This is the only path that can set a provider.
  """
  def create_changeset(skill, attrs) do
    skill
    |> cast(attrs, [:provider, :instructions | @metadata_fields])
    |> validate()
  end

  @doc """
  Metadata only. Deliberately casts neither `provider` nor `instructions`.

  `provider` is immutable because a grant list is not portable: `google_search`
  and `openrouter:web_search` are different services, not two spellings of one
  capability, so moving a skill between providers would silently drop or
  substitute part of what it was approved to do. Withholding the cast means no
  API shape, form field, or agent tool can reach it -- exactly how
  `Echo.Content.Blog.metadata_changeset/2` keeps `content` out of a metadata
  update, and why a `provider` key here is ignored rather than rejected.

  `instructions` is withheld for the blog's other reason: editing the body is a
  distinct operation from renaming the skill, which is what makes adding
  revisions cheap later.
  """
  def update_changeset(skill, attrs) do
    skill
    |> cast(attrs, @metadata_fields)
    |> validate()
  end

  @doc """
  The markdown body, saved through `Echo.Skills.update_skill_instructions/2`.
  """
  def instructions_changeset(skill, attrs) do
    skill
    |> cast(attrs, [:instructions])
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> validate_required([:slug, :name])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase letters, numbers and dashes"
    )
    |> validate_length(:name, min: 1, max: 200)
    # nil is the default (Gemini), not invalid -- `validate_inclusion` skips
    # nil, which matches `Echo.Agents.Providers.resolve/1`.
    |> validate_inclusion(:provider, Providers.names())
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:max_output_tokens, greater_than: 0)
    |> validate_tools()
    |> unique_constraint(:slug)
  end

  # An unknown name is rejected rather than ignored at run time. The allow-list
  # is provider-specific, which keeps `google_search` off an OpenRouter skill.
  # `get_field/2` falls back to the struct, so an update validates against the
  # provider already on the row.
  defp validate_tools(changeset) do
    case Providers.resolve(get_field(changeset, :provider)) do
      {:ok, provider_module} ->
        known = SkillTools.known_names(provider_module)

        validate_change(changeset, :tool_config, fn :tool_config, tool_config ->
          case unknown_names(tool_config, known) ++ bad_settings(tool_config) do
            [] -> []
            errors -> [tool_config: Enum.join(errors, "; ")]
          end
        end)

      {:error, _reason} ->
        # `validate_inclusion` already reported the bad provider; don't pile on.
        changeset
    end
  end

  defp unknown_names(tool_config, known) when is_map(tool_config) do
    case Map.keys(tool_config) -- known do
      [] -> []
      unknown -> ["unknown for this provider: #{Enum.join(Enum.sort(unknown), ", ")}"]
    end
  end

  defp unknown_names(_tool_config, _known), do: ["must be an object keyed by tool name"]

  # Refused here rather than at run time, where an unrecognised gate fails
  # closed and a typo would silently park every call.
  defp bad_settings(tool_config) when is_map(tool_config) do
    tool_config
    |> Enum.flat_map(fn
      {_name, settings} when not is_map(settings) ->
        ["each tool's settings must be an object"]

      {name, %{"gate" => gate}} when gate not in @gates ->
        ["#{name} has an unknown gate #{inspect(gate)}"]

      _ok ->
        []
    end)
    |> Enum.uniq()
  end

  defp bad_settings(_tool_config), do: []
end
