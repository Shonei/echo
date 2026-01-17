defmodule Echo.Accounts do
  @moduledoc """
  The Accounts context for user management.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo
  alias Echo.Accounts.User

  @doc """
  Creates a new user with username and password.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns the list of all users.
  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Gets a single user by id.
  Returns nil if the user does not exist.
  """
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc """
  Gets a user by username.
  Returns nil if the user does not exist.
  """
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  def get_user_by_username(_), do: nil

  @doc """
  Authenticates a user by username and password.
  Returns {:ok, user} if successful, {:error, :invalid_credentials} otherwise.
  """
  def authenticate_user(username, password) do
    user = get_user_by_username(username)

    cond do
      user && User.verify_password(user, password) ->
        {:ok, user}

      user ->
        # User exists but password is wrong
        {:error, :invalid_credentials}

      true ->
        # No user found - still run hash to prevent timing attacks
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end
end

