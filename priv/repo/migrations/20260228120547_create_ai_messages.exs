defmodule Echo.Repo.Migrations.CreateAiMessages do
  use Ecto.Migration

  def change do
    create table(:ai_messages) do
      add :session_id, :string
      add :content, :text
      add :role, :string
      add :model, :string
      add :type, :string
      add :payload, :map
      add :reference_type, :string
      add :reference_id, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:ai_messages, [:session_id, :inserted_at])
    # Explicit name: the generated one is 68 characters and Postgres silently
    # truncates identifiers at 63, after which drop index cannot find it.
    create index(:ai_messages, [:reference_type, :reference_id, :session_id, :inserted_at],
             name: :ai_messages_reference_session_inserted_at_index
           )
  end
end
