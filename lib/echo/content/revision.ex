defmodule Echo.Content.Revision do
  use Ecto.Schema
  import Ecto.Changeset

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
