defmodule Echo.Repo.Migrations.AddVariableScopeToAiConversations do
  use Ecto.Migration

  # variable_scope: an opaque token ("skill:12") naming where this
  # conversation's $.name placeholders resolve from. Stored rather than derived,
  # because init/1 rebuilds from this table on every resume. Null means no
  # variables.
  #
  # tool_config: what Echo may execute here, and how. Separate from `tools`,
  # which is the payload sent to the provider. Null derives it from `tools`, so
  # existing conversations are unchanged.
  def change do
    alter table(:ai_conversations) do
      add :variable_scope, :text

      add :tool_config, :map
    end
  end
end
