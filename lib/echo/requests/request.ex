defmodule Echo.Requests.Request do
  use Ecto.Schema
  import Ecto.Changeset

  schema "requests" do
    # body, headers and url_query hold JSON text, not binary. They were declared
    # :binary (bytea on Postgres), which made them unusable with ilike/2 in
    # Echo.Requests.search/1 — Postgres has no LIKE operator for bytea. The
    # columns were converted to text in the widen_text_columns migration.
    field :body, :string, default: ""
    field :headers, :string, default: ""
    field :url_path, :string, default: ""
    field :method, :string
    field :content_type, :string, default: ""
    field :url_query, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:url_path, :method, :content_type, :body, :headers, :url_query])
    |> validate_required([:method])
  end
end
