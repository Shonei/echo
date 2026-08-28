defmodule Echo.Repo.Migrations.AddVariableScopeToAiConversations do
  use Ecto.Migration

  # Where a conversation's `$.name` placeholders resolve from. Opaque to
  # everything in `Echo.Agents`: it is handed to the configured
  # `Echo.Agents.VariableResolver` and never parsed there.
  #
  # Durable for the same reason `provider` is. `ConversationServer.init/1`
  # rebuilds its whole config from this table on every resume, so a scope held
  # only in memory would come back nil after a restart and silently send
  # `$.token` to a tool as a literal.
  #
  # It has to be stored rather than derived: `skill_runs.session_id` points the
  # other way, and cannot be looked up in time --
  # `ConversationManager.start_conversation/1` generates the session id itself
  # and runs `init/1` synchronously inside that call, so the run row has no
  # session id yet when the first tool round executes. Today it holds
  # `"skill:<id>"`, since variables belong to the skill.
  #
  # Null means "no variables", which is every conversation predating this and
  # every plain agent chat. That is a fast path, not a special case: no scope
  # means no resolver call and no behaviour change at all.
  def change do
    alter table(:ai_conversations) do
      add :variable_scope, :text
    end
  end
end
