defmodule Echo.Repo.Migrations.CreateChatRoom do
  use Ecto.Migration

  def change do
    create table(:chat_room) do
      add :name, :string
      add :description, :string
      add :type, :string
      add :password, :string

      timestamps(type: :utc_datetime)
    end
  end
end
