defmodule Echo.Requests.Request do
  use Ecto.Schema
  import Ecto.Changeset

  schema "requests" do
    field :body, :binary, default: ""
    field :headers, :binary, default: ""
    field :url_path, :string, default: ""
    field :method, :string
    field :content_type, :string, default: ""
    field :url_query, :binary, default: ""

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:url_path, :method, :content_type, :body, :headers, :url_query])
    |> validate_required([:method])
  end
end
