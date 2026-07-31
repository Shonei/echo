defmodule Echo.Content.Blog do
  use Ecto.Schema
  import Ecto.Changeset

  #  blogs are the contents of a blog
  #  they might have 0 or many revions if the author wants to revert to a previous version
  schema "blogs" do
    field :title, :string
    field :slug, :string
    field :status, :string, default: "draft"
    field :icon, :string
    field :background_image, :string
    field :cover_image, :string
    field :thumbnail_image, :string
    field :description, :string
    field :content, :string

    # a json map of string string pairs
    field :tags, :string

    has_many :revisions, Echo.Content.Revision

    timestamps(type: :utc_datetime)
  end

  @metadata_fields [
    :title,
    :slug,
    :status,
    :icon,
    :background_image,
    :cover_image,
    :thumbnail_image,
    :description,
    :tags
  ]

  @doc false
  def changeset(blog, attrs) do
    blog
    |> cast(attrs, [:content | @metadata_fields])
    |> validate()
  end

  @doc """
  Changeset for everything except the content.

  Content is saved through `Echo.Content.update_blog_content/2` so that the
  replaced version is always snapshotted as a revision first; casting it here too
  would let a metadata update slip past that.
  """
  def metadata_changeset(blog, attrs) do
    blog
    |> cast(attrs, @metadata_fields)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> validate_required([:title, :slug, :status])
    |> validate_inclusion(:status, ["draft", "public", "private"])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase letters, numbers and dashes"
    )
    |> unique_constraint(:slug)
  end
end
