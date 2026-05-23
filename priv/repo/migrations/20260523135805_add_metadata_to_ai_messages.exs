defmodule Echo.Repo.Migrations.AddMetadataToAiMessages do
  use Ecto.Migration

  def change do
    alter table(:ai_messages) do
      add :metadata, :map, default: %{}
    end
  end
end
