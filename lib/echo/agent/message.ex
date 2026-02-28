defmodule Echo.Agent.Message do
  @moduledoc """
  Schema for storing AI messages in the database.

  This will be used to store the conversation history between the user and the AI.
  Here is the general layout of the convos:
  - session_id: to track and group messages together
  - role: the role of the message sender (user or agent)
  - model: the model used to generate the message
  - type: the type of message (e.g., "text", "functionCall", "functionResponse", "document")
  - content: This is the content when the type is "text"
  - payload: This is only set when the type is "functionCall" or "functionResponse"
  - reference_type: Messages can be related to any resouces on the system. Right now we only have "blog"
  - reference_id: The id of the resource that the message is related to.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_messages" do
    field :session_id, :string
    field :content, :string
    field :role, :string
    field :model, :string
    field :type, :string
    field :payload, :map
    field :reference_type, :string
    field :reference_id, :integer

    timestamps(type: :utc_datetime)
  end
end
