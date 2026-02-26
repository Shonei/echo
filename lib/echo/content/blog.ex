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

  @doc false
  def changeset(blog, attrs) do
    blog
    |> cast(attrs, [
      :title,
      :slug,
      :status,
      :icon,
      :background_image,
      :cover_image,
      :thumbnail_image,
      :description,
      :content,
      :tags
    ])
    |> validate_required([:title, :slug, :status])
    |> validate_inclusion(:status, ["draft", "public", "private"])
    |> unique_constraint(:slug)
  end
end
