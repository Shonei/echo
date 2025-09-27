defmodule EchoWeb.UserWebController do
  use EchoWeb, :controller

  alias Echo.Accounts
  alias Echo.Accounts.User

  def index(conn, _params) do
    users = Accounts.list_users()
    render(conn, :index, users: users)
  end

  def show(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        metadata = Accounts.get_user_metadata(user)
        render(conn, :show, user: user, metadata: metadata)

      nil ->
        conn
        |> put_flash(:error, "User not found")
        |> redirect(to: ~p"/users")
    end
  end

  def new(conn, _params) do
    changeset = Accounts.change_user(%User{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    # Parse metadata if it's a JSON string
    user_params = parse_metadata(user_params)

    case user_params["type"] do
      "ai" ->
        case Accounts.create_ai_user(user_params) do
          {:ok, user} ->
            conn
            |> put_flash(:info, "AI User created successfully.")
            |> redirect(to: ~p"/users/#{user}")

          {:error, %Ecto.Changeset{} = changeset} ->
            render(conn, :new, changeset: changeset)
        end

      _ ->
        case Accounts.create_user(user_params) do
          {:ok, user} ->
            conn
            |> put_flash(:info, "User created successfully.")
            |> redirect(to: ~p"/users/#{user}")

          {:error, %Ecto.Changeset{} = changeset} ->
            render(conn, :new, changeset: changeset)
        end
    end
  end

  def edit(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        changeset = Accounts.change_user(user)
        metadata = Accounts.get_user_metadata(user)
        render(conn, :edit, user: user, changeset: changeset, metadata: metadata)

      nil ->
        conn
        |> put_flash(:error, "User not found")
        |> redirect(to: ~p"/users")
    end
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        # Parse metadata if it's a JSON string
        user_params = parse_metadata(user_params)
        current_password = user_params["current_password"]

        if current_password && current_password != "" do
          case Accounts.update_user(user, user_params, current_password) do
            {:ok, user} ->
              conn
              |> put_flash(:info, "User updated successfully.")
              |> redirect(to: ~p"/users/#{user}")

            {:error, %Ecto.Changeset{} = changeset} ->
              metadata = Accounts.get_user_metadata(user)
              render(conn, :edit, user: user, changeset: changeset, metadata: metadata)
          end
        else
          conn
          |> put_flash(:error, "Current password is required to update user information.")
          |> redirect(to: ~p"/users/#{user}/edit")
        end

      nil ->
        conn
        |> put_flash(:error, "User not found")
        |> redirect(to: ~p"/users")
    end
  end

  def delete(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        {:ok, _user} = Accounts.delete_user(user)

        conn
        |> put_flash(:info, "User deleted successfully.")
        |> redirect(to: ~p"/users")

      nil ->
        conn
        |> put_flash(:error, "User not found")
        |> redirect(to: ~p"/users")
    end
  end

  def by_type(conn, %{"type" => type}) do
    users = Accounts.list_users_by_type(type)
    render(conn, :by_type, users: users, type: type)
  end

  defp parse_metadata(%{"metadata" => metadata_string} = params) when is_binary(metadata_string) do
    case Jason.decode(metadata_string) do
      {:ok, metadata} when is_map(metadata) ->
        Map.put(params, "metadata", metadata)

      _ ->
        params
    end
  end

  defp parse_metadata(params), do: params
end
