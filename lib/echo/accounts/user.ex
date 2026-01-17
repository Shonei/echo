defmodule Echo.Accounts.User do
  @moduledoc """
  Schema for user authentication.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :password_hash, :string
    field :metadata, :map, default: %{}

    # Virtual field for password input
    field :password, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new user.
  Requires username and password, hashes password before storing.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :metadata])
    |> validate_required([:username, :password])
    |> validate_length(:username, min: 3, max: 50)
    |> validate_length(:password, min: 8, max: 100)
    |> validate_metadata()
    |> unique_constraint(:username)
    |> hash_password()
  end

  @doc """
  Basic changeset for updates (not including password).
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :metadata])
    |> validate_required([:username])
    |> validate_length(:username, min: 3, max: 50)
    |> validate_metadata()
    |> unique_constraint(:username)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  defp validate_metadata(changeset) do
    case get_change(changeset, :metadata) do
      nil ->
        changeset

      metadata when is_map(metadata) ->
        # Ensure all keys and values are strings
        if Enum.all?(metadata, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          changeset
        else
          add_error(changeset, :metadata, "must be a map of string/string pairs")
        end

      _ ->
        add_error(changeset, :metadata, "must be a map")
    end
  end

  @doc """
  Verifies the password against the stored hash.
  """
  def verify_password(%__MODULE__{password_hash: hash}, password) when is_binary(password) do
    Bcrypt.verify_pass(password, hash)
  end

  def verify_password(_, _), do: false
end

