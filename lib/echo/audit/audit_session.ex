defmodule Echo.AuditSession do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_sessions" do
    field :session_hash, :string
    field :system_prompt, :string
    field :created_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(audit_session, attrs) do
    audit_session
    |> cast(attrs, [:session_hash, :system_prompt, :created_at])
    |> validate_required([:session_hash, :system_prompt, :created_at])
  end
end
