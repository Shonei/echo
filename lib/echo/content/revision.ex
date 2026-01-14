defmodule Echo.Content.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  # blog revions are just versions of a blog we can load and create
  # they are not the current version of a blog but more of backups
  # We can create a revision but to revert a revion it will be to the UI to load a revion and update a blog
  schema "blog_revisions" do
    field :content, :string
    field :note, :string
    field :version, :integer

    belongs_to :blog, Echo.Content.Blog

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:content, :note, :version, :blog_id])
    |> validate_required([:content, :version])
  end
end
