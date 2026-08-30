defmodule Echo.Repo.Migrations.ReconcileSkillToolConfig do
  use Ecto.Migration

  # Repairs a database that ran an earlier revision of the two migrations above,
  # which were edited in place before they had shipped. Every statement is
  # guarded, so this is a no-op on a database built from the current ones.
  def up do
    execute "ALTER TABLE skills ADD COLUMN IF NOT EXISTS tool_config jsonb NOT NULL DEFAULT '{}'::jsonb"
    execute "ALTER TABLE skills DROP COLUMN IF EXISTS tools"
    execute "ALTER TABLE skills DROP COLUMN IF EXISTS gated_tools"

    execute "ALTER TABLE skill_variables DROP COLUMN IF EXISTS oauth_provider"
    execute "ALTER TABLE skill_variables DROP COLUMN IF EXISTS secret_id"
    execute "ALTER TABLE skill_variables DROP COLUMN IF EXISTS connection_id"

    execute "ALTER TABLE ai_conversations ADD COLUMN IF NOT EXISTS tool_config jsonb"
  end

  # Deliberately partial: the shape this rolls back to was never released.
  def down do
    execute "ALTER TABLE ai_conversations DROP COLUMN IF EXISTS tool_config"
    execute "ALTER TABLE skills DROP COLUMN IF EXISTS tool_config"
  end
end
