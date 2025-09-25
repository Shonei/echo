defmodule Echo.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :metadata, :binary
    field :type, :string, default: "user"

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :type])
    |> validate_required([:username, :password, :type])
    |> validate_length(:username, min: 2, max: 50)
    |> validate_length(:password, min: 6, max: 100)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "can only contain letters, numbers, and underscores"
    )
    |> unique_constraint(:username)
    |> validate_inclusion(:type, ["user", "ai", "admin"])
    |> put_password_hash()
    |> put_metadata(attrs)
  end

  @doc false
  def update_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :type])
    |> validate_length(:username, min: 3, max: 50)
    |> validate_length(:password, min: 6, max: 100)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "can only contain letters, numbers, and underscores"
    )
    |> unique_constraint(:username)
    |> validate_inclusion(:type, ["user", "ai", "admin"])
    |> put_password_hash()
    |> put_metadata(attrs)
  end

  defp put_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    change(changeset, password_hash: Bcrypt.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset

  defp put_metadata(changeset, %{"metadata" => metadata}) when is_map(metadata) do
    encoded_metadata = :erlang.term_to_binary(metadata)
    change(changeset, metadata: encoded_metadata)
  end

  defp put_metadata(changeset, %{metadata: metadata}) when is_map(metadata) do
    encoded_metadata = :erlang.term_to_binary(metadata)
    change(changeset, metadata: encoded_metadata)
  end

  defp put_metadata(changeset, _attrs), do: changeset

  @doc """
  Verifies the password against the stored hash.
  """
  def valid_password?(%Echo.Accounts.User{password_hash: hash}, password)
      when is_binary(hash) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Decodes the metadata binary field into a map.
  """
  def decode_metadata(%Echo.Accounts.User{metadata: nil}), do: %{}

  def decode_metadata(%Echo.Accounts.User{metadata: metadata}) when is_binary(metadata) do
    try do
      :erlang.binary_to_term(metadata)
    rescue
      _ -> %{}
    end
  end

  def decode_metadata(_), do: %{}

  @doc """
  Encodes a map into binary format for storage.
  """
  def encode_metadata(metadata) when is_map(metadata) do
    :erlang.term_to_binary(metadata)
  end

  def encode_metadata(_), do: nil

  @doc """
  Creates a changeset for AI user type with specific metadata validation.
  """
  def ai_changeset(user, attrs) do
    user
    |> changeset(Map.put(attrs, "type", "ai"))
    |> validate_ai_metadata(attrs)
  end

  defp validate_ai_metadata(changeset, %{"metadata" => metadata}) when is_map(metadata) do
    case {Map.get(metadata, "model"), Map.get(metadata, "system_props")} do
      {nil, _} ->
        add_error(changeset, :metadata, "AI users must have a 'model' in metadata")

      {_, nil} ->
        add_error(changeset, :metadata, "AI users must have 'system_props' in metadata")

      {model, system_props} when is_binary(model) and is_map(system_props) ->
        changeset

      _ ->
        add_error(
          changeset,
          :metadata,
          "AI metadata must have 'model' as string and 'system_props' as map"
        )
    end
  end

  defp validate_ai_metadata(changeset, %{metadata: metadata}) when is_map(metadata) do
    case {Map.get(metadata, :model), Map.get(metadata, :system_props)} do
      {nil, _} ->
        add_error(changeset, :metadata, "AI users must have a 'model' in metadata")

      {_, nil} ->
        add_error(changeset, :metadata, "AI users must have 'system_props' in metadata")

      {model, system_props} when is_binary(model) and is_binary(system_props) ->
        changeset

      _ ->
        add_error(
          changeset,
          :metadata,
          "AI metadata must have 'model' as string and 'system_props' as map"
        )
    end
  end

  defp validate_ai_metadata(changeset, _attrs) do
    add_error(changeset, :metadata, "AI users must have metadata with 'model' and 'system_props'")
  end
end
