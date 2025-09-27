defmodule Echo.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.Accounts.User

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Returns the list of users with a specific type.

  ## Examples

      iex> list_users_by_type("ai")
      [%User{}, ...]

  """
  def list_users_by_type(type) do
    User
    |> where([u], u.type == ^type)
    |> Repo.all()
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user by ID.

  Returns nil if the User does not exist.

  ## Examples

      iex> get_user(123)
      %User{}

      iex> get_user(456)
      nil

  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Gets a single user by username.

  Returns nil if the User does not exist.

  ## Examples

      iex> get_user_by_username("john_doe")
      %User{}

      iex> get_user_by_username("nonexistent")
      nil

  """
  def get_user_by_username(username) do
    User
    |> where([u], u.username == ^username)
    |> Repo.one()
  end

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    case %User{}
         |> User.changeset(attrs)
         |> Repo.insert() do
      {:ok, user} = result ->
        # Update AI User Registry if this is an AI user
        if user.type == "ai" do
          Echo.AIUserRegistry.add_or_update_ai_user(user)
        end

        result

      error ->
        error
    end
  end

  @doc """
  Creates an AI user with specific metadata validation.

  ## Examples

      iex> create_ai_user(%{username: "ai_bot", password: "secret", metadata: %{"model" => "gpt-4", "system_props" => %{}}})
      {:ok, %User{}}

      iex> create_ai_user(%{username: "ai_bot", password: "secret", metadata: %{}})
      {:error, %Ecto.Changeset{}}

  """
  def create_ai_user(attrs \\ %{}) do
    case %User{}
         |> User.ai_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} = result ->
        # Update AI User Registry
        Echo.AIUserRegistry.add_or_update_ai_user(user)
        result

      error ->
        error
    end
  end

  @doc """
  Updates a user after verifying the current password.

  ## Examples

      iex> update_user(user, %{field: new_value}, "current_password")
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value}, "wrong_password")
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs, current_password) do
    if User.valid_password?(user, current_password) do
      user
      |> User.update_changeset(attrs)
      |> Repo.update()
    else
      {:error,
       %Ecto.Changeset{data: user, valid?: false}
       |> Ecto.Changeset.add_error(:current_password, "is invalid")}
    end
  end

  @doc """
  Updates a user without password verification (admin function).

  ## Examples

      iex> admin_update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> admin_update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def admin_update_user(%User{} = user, attrs) do
    old_type = user.type
    old_username = user.username

    case user
         |> User.update_changeset(attrs)
         |> Repo.update() do
      {:ok, updated_user} = result ->
        # Handle AI User Registry updates
        cond do
          # User changed from AI to non-AI
          old_type == "ai" and updated_user.type != "ai" ->
            Echo.AIUserRegistry.remove_ai_user(old_username)

          # User changed to AI or updated AI user
          updated_user.type == "ai" ->
            Echo.AIUserRegistry.add_or_update_ai_user(updated_user)

          # Username changed for AI user
          old_username != updated_user.username and updated_user.type == "ai" ->
            Echo.AIUserRegistry.remove_ai_user(old_username)
            Echo.AIUserRegistry.add_or_update_ai_user(updated_user)

          true ->
            :ok
        end

        result

      error ->
        error
    end
  end

  @doc """
  Deletes a user.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    case Repo.delete(user) do
      {:ok, deleted_user} = result ->
        # Remove from AI User Registry if it was an AI user
        if deleted_user.type == "ai" do
          Echo.AIUserRegistry.remove_ai_user(deleted_user.username)
        end

        result

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  @doc """
  Authenticates a user by username and password.

  ## Examples

      iex> authenticate_user("john_doe", "correct_password")
      {:ok, %User{}}

      iex> authenticate_user("john_doe", "wrong_password")
      {:error, :invalid_credentials}

      iex> authenticate_user("nonexistent", "password")
      {:error, :invalid_credentials}

  """
  def authenticate_user(username, password) do
    case get_user_by_username(username) do
      %User{} = user ->
        if User.valid_password?(user, password) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      nil ->
        # Run password verification to prevent timing attacks
        User.valid_password?(nil, password)
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Gets user metadata as a decoded map.

  ## Examples

      iex> get_user_metadata(user)
      %{"key" => "value"}

  """
  def get_user_metadata(%User{} = user) do
    User.decode_metadata(user)
  end

  @doc """
  Updates user metadata.

  ## Examples

      iex> update_user_metadata(user, %{"new_key" => "new_value"})
      {:ok, %User{}}

  """
  def update_user_metadata(%User{} = user, metadata) when is_map(metadata) do
    encoded_metadata = User.encode_metadata(metadata)

    user
    |> Ecto.Changeset.change(metadata: encoded_metadata)
    |> Repo.update()
  end

  @doc """
  Merges new metadata with existing metadata for a user.

  ## Examples

      iex> merge_user_metadata(user, %{"new_key" => "new_value"})
      {:ok, %User{}}

  """
  def merge_user_metadata(%User{} = user, new_metadata) when is_map(new_metadata) do
    current_metadata = get_user_metadata(user)
    merged_metadata = Map.merge(current_metadata, new_metadata)
    update_user_metadata(user, merged_metadata)
  end

  @doc """
  Gets all AI users.

  ## Examples

      iex> list_ai_users()
      [%User{}, ...]

  """
  def list_ai_users do
    list_users_by_type("ai")
  end

  @doc """
  Gets an AI user's model from metadata.

  ## Examples

      iex> get_ai_model(ai_user)
      "gpt-4"

  """
  def get_ai_model(%User{type: "ai"} = user) do
    metadata = get_user_metadata(user)
    Map.get(metadata, "model") || Map.get(metadata, :model)
  end

  def get_ai_model(_user), do: nil

  @doc """
  Gets an AI user's system properties from metadata.

  ## Examples

      iex> get_ai_system_props(ai_user)
      %{"temperature" => 0.7, "max_tokens" => 1000}

  """
  def get_ai_system_props(%User{type: "ai"} = user) do
    metadata = get_user_metadata(user)
    Map.get(metadata, "system_props") || Map.get(metadata, :system_props) || %{}
  end

  def get_ai_system_props(_user), do: %{}

  @doc """
  Updates an AI user's model.

  ## Examples

      iex> update_ai_model(ai_user, "gpt-4-turbo")
      {:ok, %User{}}

  """
  def update_ai_model(%User{type: "ai"} = user, model) when is_binary(model) do
    current_metadata = get_user_metadata(user)
    updated_metadata = Map.put(current_metadata, "model", model)
    update_user_metadata(user, updated_metadata)
  end

  def update_ai_model(_user, _model), do: {:error, :not_ai_user}

  @doc """
  Updates an AI user's system properties.

  ## Examples

      iex> update_ai_system_props(ai_user, %{"temperature" => 0.8})
      {:ok, %User{}}

  """
  def update_ai_system_props(%User{type: "ai"} = user, system_props) when is_map(system_props) do
    current_metadata = get_user_metadata(user)
    updated_metadata = Map.put(current_metadata, "system_props", system_props)
    update_user_metadata(user, updated_metadata)
  end

  def update_ai_system_props(_user, _system_props), do: {:error, :not_ai_user}

  @doc """
  Validates if a user has valid AI metadata.

  ## Examples

      iex> valid_ai_metadata?(ai_user)
      true

  """
  def valid_ai_metadata?(%User{type: "ai"} = user) do
    metadata = get_user_metadata(user)
    model = Map.get(metadata, "model") || Map.get(metadata, :model)
    system_props = Map.get(metadata, "system_props") || Map.get(metadata, :system_props)

    is_binary(model) and is_map(system_props)
  end

  def valid_ai_metadata?(_user), do: false
end
