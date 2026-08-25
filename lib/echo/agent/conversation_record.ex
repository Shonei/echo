defmodule Echo.Agent.ConversationRecord do
  @moduledoc """
  Durable record of a conversation's configuration.

  `Echo.Agents.ConversationServer` holds a conversation's config and history
  in memory; this is the durable copy that lets it be rebuilt after the
  process (or the whole node) restarts. Named `ConversationRecord` rather than
  `Conversation` to avoid colliding with `Echo.Agents.Conversation`, the
  in-memory runtime struct.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:session_id, :string, autogenerate: false}

  schema "ai_conversations" do
    field :system_prompt, :string
    field :temperature, :float
    field :max_output_tokens, :integer
    field :thinking_enabled, :boolean, default: false
    field :thinking_budget, :integer
    field :tools, {:array, :map}
    field :model, :string
    field :response_modalities, {:array, :string}

    # Which backend this conversation talks to (see `Echo.Agents.Providers`).
    # Null means the default, so conversations predating providers resolve to
    # Gemini exactly as before.
    field :provider, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :session_id,
      :system_prompt,
      :temperature,
      :max_output_tokens,
      :thinking_enabled,
      :thinking_budget,
      :tools,
      :model,
      :response_modalities,
      :provider
    ])
    |> validate_required([:session_id])
  end
end
