defmodule Echo.Repo.Migrations.ReconcileSkillToolConfig do
  use Ecto.Migration

  # Repairs a database that ran an earlier revision of the two migrations above.
  #
  # Those were edited in place while this branch was still unmerged, which does
  # not work: `schema_migrations` records a version, not the file's contents, so
  # a database that had already run them never picked the changes up. A fresh
  # database was fine and CI's long-lived test database was not, which is the
  # worst way for that to present.
  #
  # Every statement is guarded, so this is a no-op on a database built from the
  # current create migration -- including production, which has never seen any
  # of them.
  def up do
    execute "ALTER TABLE skills ADD COLUMN IF NOT EXISTS tool_config jsonb NOT NULL DEFAULT '{}'::jsonb"
    execute "ALTER TABLE skills DROP COLUMN IF EXISTS tools"
    execute "ALTER TABLE skills DROP COLUMN IF EXISTS gated_tools"

    execute "ALTER TABLE skill_variables DROP COLUMN IF EXISTS oauth_provider"
    execute "ALTER TABLE skill_variables DROP COLUMN IF EXISTS secret_id"
    execute "ALTER TABLE skill_variables DROP COLUMN IF EXISTS connection_id"

    execute "ALTER TABLE ai_conversations ADD COLUMN IF NOT EXISTS tool_config jsonb"
  end

  # Deliberately partial. This migration exists to move a database forward onto
  # the current schema; rolling it back would mean reconstructing a shape that
  # was never released and that nothing can read.
  def down do
    execute "ALTER TABLE ai_conversations DROP COLUMN IF EXISTS tool_config"
    execute "ALTER TABLE skills DROP COLUMN IF EXISTS tool_config"
  end
end
