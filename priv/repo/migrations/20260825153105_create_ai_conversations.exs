defmodule Echo.Repo.Migrations.CreateAiConversations do
  use Ecto.Migration

  def change do
    create table(:ai_conversations, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :system_prompt, :text
      add :temperature, :float
      add :max_output_tokens, :integer
      add :thinking_enabled, :boolean, default: false
      add :thinking_budget, :integer
      add :tools, {:array, :map}
      add :model, :string
      add :response_modalities, {:array, :string}

      timestamps(type: :utc_datetime)
    end
  end
end
