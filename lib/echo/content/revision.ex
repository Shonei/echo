defmodule Echo.Content.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  # blog revions are just versions of a blog we can load and create
  # they are not the current version of a blog but more of backups
  # To revert it will be up to the UI to load a revision and update a blog
  #
  # Revisions are created automatically when a save replaces a blog's content,
  # see `Echo.Content.update_blog_content/2`. They are identified by their
  # timestamps rather than a version counter, and :blog_id is never taken from
  # user input, so `cast` only covers the two fields the snapshot supplies.
  schema "blog_revisions" do
    field :content, :string
    field :note, :string

    belongs_to :blog, Echo.Content.Blog

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:content, :note])
    |> validate_required([:content])
    |> foreign_key_constraint(:blog_id)
  end
end
