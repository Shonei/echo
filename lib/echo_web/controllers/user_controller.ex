defmodule EchoWeb.UserController do
  use EchoWeb, :controller

  alias Echo.Accounts
  alias Echo.Accounts.Token
  alias Echo.Accounts.RefreshTokenStore

  action_fallback EchoWeb.FallbackController

  @doc """
  POST /api/v1/users
  Creates a new user with username, password, and optional metadata.
  """
  def create(conn, params) do
    case Accounts.create_user(params) do
      {:ok, user} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            id: user.id,
            username: user.username,
            metadata: user.metadata,
            created_at: user.inserted_at
          }
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_changeset_errors(changeset)})
    end
  end

  @doc """
  GET /api/v1/users
  Returns a list of all users.
  """
  def index(conn, _params) do
    users = Accounts.list_users()

    conn
    |> put_status(:ok)
    |> json(%{
      data:
        Enum.map(users, fn user ->
          %{
            id: user.id,
            username: user.username,
            metadata: user.metadata,
            created_at: user.inserted_at
          }
        end)
    })
  end

  @doc """
  POST /api/v1/users/login
  Authenticates a user and returns JWT tokens.
  """
  def login(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        {:ok, access_token, _claims} = Token.generate_access_token(user)
        {:ok, refresh_token, _claims} = Token.generate_refresh_token(user)

        # Store refresh token in memory
        RefreshTokenStore.store(refresh_token, user.id, access_token)

        conn
        |> put_status(:ok)
        |> json(%{
          token: access_token,
          refresh_token: refresh_token
        })

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid username or password"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing username or password"})
  end

  @doc """
  POST /api/v1/users/refresh
  Refreshes the access token using a valid refresh token.
  """
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    with {:ok, claims} <- Token.verify_refresh_token(refresh_token),
         {:ok, _stored} <- RefreshTokenStore.get(refresh_token),
         user when not is_nil(user) <- Accounts.get_user(claims["sub"]) do
      # Invalidate old refresh token
      RefreshTokenStore.invalidate(refresh_token)

      # Generate new tokens
      {:ok, new_access_token, _claims} = Token.generate_access_token(user)
      {:ok, new_refresh_token, _claims} = Token.generate_refresh_token(user)

      # Store new refresh token
      RefreshTokenStore.store(new_refresh_token, user.id, new_access_token)

      conn
      |> put_status(:ok)
      |> json(%{
        token: new_access_token,
        refresh_token: new_refresh_token
      })
    else
      {:error, :not_found} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or expired refresh token"})

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or expired refresh token"})

      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "User not found"})
    end
  end

  def refresh(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing refresh_token"})
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

