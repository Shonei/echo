defmodule Echo.Storage.Asset do
  @moduledoc """
  Schema for storing asset metadata in the database.

  Assets are files stored in S3 and can optionally be linked to other resources
  like blogs through reference_type and reference_id.

  File metadata (`filename`, `byte_size`, `width`, `height`, `variant`,
  `content_hash`) is filled in on upload. Existing rows get `filename` and
  `variant` inferred from the storage key; size, dimensions, and content
  hash stay empty.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @variants ~w(original background content thumbnail)

  schema "assets" do
    field :name, :string
    field :url, :string
    field :url_suffix, :string
    field :content_type, :string
    field :reference_type, :string
    field :reference_id, :integer
    field :original_hash, :string
    field :filename, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :variant, :string
    field :content_hash, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :name,
      :url,
      :url_suffix,
      :content_type,
      :reference_type,
      :reference_id,
      :original_hash,
      :filename,
      :byte_size,
      :width,
      :height,
      :variant,
      :content_hash
    ])
    |> validate_required([:name, :url, :url_suffix, :content_type])
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_inclusion(:variant, @variants)
    |> validate_reference()
  end

  # If reference_type is provided, reference_id must also be provided
  defp validate_reference(changeset) do
    reference_type = get_field(changeset, :reference_type)
    reference_id = get_field(changeset, :reference_id)

    cond do
      reference_type && !reference_id ->
        add_error(changeset, :reference_id, "is required when reference_type is provided")

      reference_id && !reference_type ->
        add_error(changeset, :reference_type, "is required when reference_id is provided")

      reference_type && reference_type not in ["blog"] ->
        add_error(changeset, :reference_type, "must be one of: blog")

      true ->
        changeset
    end
  end
end
