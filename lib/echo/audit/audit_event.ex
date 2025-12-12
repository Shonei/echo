defmodule Echo.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_events" do
    field :session_hash, :string
    field :type, :string
    field :created_at, :utc_datetime
    field :payload, :binary
    field :content, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [:session_hash, :type, :created_at, :payload, :content])
    |> validate_required([:session_hash, :type, :created_at, :payload, :content])
  end
end
