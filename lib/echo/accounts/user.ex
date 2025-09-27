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
    case validate_metadata_structure(metadata) do
      :ok ->
        encoded_metadata = :erlang.term_to_binary(metadata)
        change(changeset, metadata: encoded_metadata)

      {:error, message} ->
        add_error(changeset, :metadata, message)
    end
  end

  defp put_metadata(changeset, %{metadata: metadata}) when is_map(metadata) do
    case validate_metadata_structure(metadata) do
      :ok ->
        encoded_metadata = :erlang.term_to_binary(metadata)
        change(changeset, metadata: encoded_metadata)

      {:error, message} ->
        add_error(changeset, :metadata, message)
    end
  end

  defp put_metadata(changeset, _attrs), do: changeset

  # Validates that metadata has string keys and string/number values only.
  defp validate_metadata_structure(metadata) when is_map(metadata) do
    case validate_metadata_keys_and_values(metadata) do
      :ok -> :ok
      error -> error
    end
  end

  defp validate_metadata_structure(_), do: {:error, "metadata must be a map"}

  defp validate_metadata_keys_and_values(metadata) do
    Enum.reduce_while(metadata, :ok, fn {key, value}, _acc ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, "all metadata keys must be strings"}}

        not (is_binary(value) or is_number(value)) ->
          {:halt, {:error, "all metadata values must be strings or numbers"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

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
    validate_ai_metadata_fields(changeset, metadata)
  end

  defp validate_ai_metadata(changeset, %{metadata: metadata}) when is_map(metadata) do
    # Convert atom keys to string keys for consistent validation
    string_metadata =
      metadata
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()

    validate_ai_metadata_fields(changeset, string_metadata)
  end

  defp validate_ai_metadata(changeset, _attrs) do
    add_error(
      changeset,
      :metadata,
      "AI users must have metadata with 'model', 'prompt', 'temperature', and 'max_tokens'"
    )
  end

  defp validate_ai_metadata_fields(changeset, metadata) do
    required_fields = ["model", "prompt", "temperature", "max_tokens"]

    missing_fields =
      required_fields
      |> Enum.filter(fn field -> is_nil(Map.get(metadata, field)) end)

    if length(missing_fields) > 0 do
      add_error(changeset, :metadata, "AI users must have: #{Enum.join(missing_fields, ", ")}")
    else
      validate_ai_field_types(changeset, metadata)
    end
  end

  defp validate_ai_field_types(changeset, metadata) do
    model = Map.get(metadata, "model")
    prompt = Map.get(metadata, "prompt")
    temperature = Map.get(metadata, "temperature")
    max_tokens = Map.get(metadata, "max_tokens")

    cond do
      not is_binary(model) ->
        add_error(changeset, :metadata, "'model' must be a string")

      not is_binary(prompt) ->
        add_error(changeset, :metadata, "'prompt' must be a string")

      not (is_binary(temperature) or is_number(temperature)) ->
        add_error(changeset, :metadata, "'temperature' must be a string or number")

      not (is_binary(max_tokens) or is_number(max_tokens)) ->
        add_error(changeset, :metadata, "'max_tokens' must be a string or number")

      true ->
        changeset
    end
  end
end
