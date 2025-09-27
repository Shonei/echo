defmodule EchoWeb.UserController do
  use EchoWeb, :controller

  alias Echo.Accounts
  alias Echo.Accounts.User

  action_fallback EchoWeb.FallbackController

  def index(conn, _params) do
    users = Accounts.list_users()
    render(conn, :index, users: users)
  end

  def create(conn, %{"user" => user_params}) do
    case user_params["type"] do
      "ai" ->
        case Accounts.create_ai_user(user_params) do
          {:ok, user} ->
            conn
            |> put_status(:created)
            |> put_resp_header("location", ~p"/api/v1/users/#{user}")
            |> render(:show, user: user)

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render(:error, changeset: changeset)
        end

      _ ->
        case Accounts.create_user(user_params) do
          {:ok, user} ->
            conn
            |> put_status(:created)
            |> put_resp_header("location", ~p"/api/v1/users/#{user}")
            |> render(:show, user: user)

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render(:error, changeset: changeset)
        end
    end
  end

  def show(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        render(conn, :show, user: user)

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        current_password = user_params["current_password"]

        if current_password do
          case Accounts.update_user(user, user_params, current_password) do
            {:ok, user} ->
              render(conn, :show, user: user)

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> render(:error, changeset: changeset)
          end
        else
          conn
          |> put_status(:bad_request)
          |> json(%{error: "current_password is required for user updates"})
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end

  def delete(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        with {:ok, %User{}} <- Accounts.delete_user(user) do
          send_resp(conn, :no_content, "")
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end

  def authenticate(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        render(conn, :show, user: user)

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid credentials"})
    end
  end

  def by_type(conn, %{"type" => type}) do
    users = Accounts.list_users_by_type(type)
    render(conn, :index, users: users)
  end

  def metadata(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        metadata = Accounts.get_user_metadata(user)
        json(conn, %{metadata: metadata})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end

  def update_metadata(conn, %{"id" => id, "metadata" => metadata}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        case Accounts.update_user_metadata(user, metadata) do
          {:ok, user} ->
            render(conn, :show, user: user)

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render(:error, changeset: changeset)
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end
end
