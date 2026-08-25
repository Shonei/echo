defmodule Echo.Agent do
  @moduledoc """
  The context module for AI Agents.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo
  alias Echo.Agent.Message
  alias Echo.Agent.ConversationRecord

  @doc """
  Returns a list of conversations by finding all messages with the role 'system'.
  """
  def list_conversations do
    Repo.all(
      from m in Message,
        where: m.role == "system",
        order_by: [desc: m.inserted_at]
    )
  end

  @doc """
  Returns the list of messages for a given session, oldest first.

  Ordered by `id` rather than `inserted_at`: insertion order is what matters
  for replaying a conversation, and `id` (an auto-incrementing serial) can't
  tie the way a timestamp can under back-to-back writes.

  ## Examples

      iex> list_messages_by_session("session_123")
      [%Message{}, ...]

  """
  def list_messages_by_session(session_id) do
    Repo.all(
      from m in Message, where: m.session_id == ^session_id, order_by: [asc: m.id]
    )
  end

  @doc """
  Gets a single message.
  Raises `Ecto.NoResultsError` if the Message does not exist.

  ## Examples

      iex> get_message!(123)
      %Message{}

      iex> get_message!(456)
      ** (Ecto.NoResultsError)

  """
  def get_message!(id), do: Repo.get!(Message, id)

  @doc """
  Creates a message.

  ## Examples

      iex> create_message(%{field: value})
      {:ok, %Message{}}

      iex> create_message(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_message(attrs \\ %{}) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a message.

  ## Examples

      iex> update_message(message, %{field: new_value})
      {:ok, %Message{}}

      iex> update_message(message, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_message(%Message{} = message, attrs) do
    message
    |> Message.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a message.

  ## Examples

      iex> delete_message(message)
      {:ok, %Message{}}

      iex> delete_message(message)
      {:error, %Ecto.Changeset{}}

  """
  def delete_message(%Message{} = message) do
    Repo.delete(message)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking message changes.

  ## Examples

      iex> change_message(message)
      %Ecto.Changeset{data: %Message{}}

  """
  def change_message(%Message{} = message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end

  @doc """
  Creates the durable record of a conversation's configuration, plus its one
  system-prompt message (if a system prompt was given). Both are written in
  one transaction, since a `ConversationRecord` without its system message
  (or vice versa) would leave a partially-created conversation behind.

  This is the only place a system-prompt message gets written, so replaying
  a conversation's history (see `Echo.Agents.ConversationServer.init/1`)
  never sees it duplicated across restarts.

  `opts` accepts either atom or string keys, matching every existing caller
  of `Echo.Agents.ConversationManager.start_conversation/1`.

  Returns `{:ok, %ConversationRecord{}}` or `{:error, reason}`.
  """
  def create_conversation(opts) do
    attrs = %{
      "session_id" => opt(opts, :session_id, "session_id"),
      "system_prompt" => opt(opts, :system_prompt, "system_prompt"),
      "temperature" => opt(opts, :temperature, "temperature"),
      "max_output_tokens" => opt(opts, :max_output_tokens, "max_output_tokens"),
      "thinking_enabled" => opt(opts, :thinking_enabled, "thinking_enabled"),
      "thinking_budget" => opt(opts, :thinking_budget, "thinking_budget"),
      "tools" => opt(opts, :tools, "tools"),
      "model" => opt(opts, :model, "model"),
      "response_modalities" => opt(opts, :response_modalities, "response_modalities")
    }

    Repo.transaction(fn ->
      with {:ok, record} <-
             %ConversationRecord{} |> ConversationRecord.changeset(attrs) |> Repo.insert(),
           :ok <- maybe_store_system_prompt(record) do
        record
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Gets the durable record of a conversation's configuration, or `nil` if none
  exists (never created, or deleted via `delete_conversation/1`).
  """
  def get_conversation(session_id), do: Repo.get(ConversationRecord, session_id)

  @doc """
  Deletes the durable record of a conversation's configuration. Message
  history in `ai_messages` is left alone. This is what makes an explicit
  delete stick against `Echo.Agents.ConversationManager`'s transparent
  resume-from-DB path — without it, the next message to that id would just
  rehydrate the "deleted" conversation.
  """
  def delete_conversation(session_id) do
    Repo.delete_all(from c in ConversationRecord, where: c.session_id == ^session_id)
    :ok
  end

  defp opt(opts, atom_key, string_key), do: Map.get(opts, atom_key) || Map.get(opts, string_key)

  defp maybe_store_system_prompt(%ConversationRecord{system_prompt: nil}), do: :ok

  defp maybe_store_system_prompt(%ConversationRecord{} = record) do
    case create_message(%{
           session_id: record.session_id,
           role: "system",
           type: "text",
           content: record.system_prompt,
           model: record.model
         }) do
      {:ok, _message} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end
