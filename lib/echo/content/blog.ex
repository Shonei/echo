defmodule Echo.Content.Blog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "blogs" do
    field :title, :string
    field :slug, :string
    field :status, :string, default: "draft"
    field :icon, :string
    field :background_image, :string
    field :cover_image, :string
    field :description, :string
    belongs_to :revision, Echo.Content.Revision

    has_many :revisions, Echo.Content.Revision

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(blog, attrs) do
    blog
    |> cast(attrs, [:title, :slug, :status, :revision_id])
    |> validate_required([:title, :slug, :status])
    |> validate_inclusion(:status, ["draft", "public", "private"])
    |> unique_constraint(:slug)
  end
end
