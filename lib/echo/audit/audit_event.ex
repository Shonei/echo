defmodule Echo.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "audit_events" do
    belongs_to :session, Echo.AuditSession, type: :string
    field :type, :string
    field :created_at, :utc_datetime
    field :payload, :map
    field :content, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [:id, :session_id, :type, :created_at, :payload, :content])
    |> validate_required([:id, :session_id, :type, :created_at, :payload, :content])
  end
end
