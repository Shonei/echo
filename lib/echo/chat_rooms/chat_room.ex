defmodule Echo.ChatRooms.ChatRoom do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_room" do
    field :name, :string
    field :type, :string
    field :description, :string
    field :password, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chat_room, attrs) do
    chat_room
    |> cast(attrs, [:name, :description, :type, :password])
    |> validate_required([:name, :description, :type, :password])
  end
end
