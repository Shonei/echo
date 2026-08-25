defmodule Echo.Repo.Migrations.AddProviderToAiConversations do
  use Ecto.Migration

  # Which backend a conversation talks to has to be durable, not a start-up
  # argument: `Echo.Agents.ConversationServer.init/1` rebuilds its whole config
  # from this table on every resume, and pushes to `elixir` deploy straight to
  # prod, wiping the registry each time. A provider held only in memory would
  # silently fall back to the default on the next message.
  #
  # Null means "the default" (Gemini), so every conversation that predates this
  # column keeps behaving exactly as it did.
  def change do
    alter table(:ai_conversations) do
      add :provider, :string
    end
  end
end
