defmodule Echo.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field :content, :string
    field :room, :string
    field :user_id, :string
    field :username, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:content, :room, :user_id, :username])
    |> validate_required([:content, :room, :user_id, :username])
    |> validate_length(:content, min: 1, max: 1000)
    |> validate_length(:room, min: 1, max: 100)
    |> validate_length(:username, min: 1, max: 50)
  end
end
