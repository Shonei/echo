defmodule EchoWeb.Plugs.UserAuth do
  @moduledoc """
  Plug for authenticating users via JWT access tokens.
  Expects the token in the Authorization header as "Bearer <token>".
  """
  import Plug.Conn

  alias Echo.Accounts.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        verify_token(conn, token)

      _ ->
        unauthorized(conn)
    end
  end

  defp verify_token(conn, token) do
    case Token.verify_access_token(token) do
      {:ok, claims} ->
        conn
        |> assign(:current_user_id, claims["sub"])
        |> assign(:current_username, claims["username"])

      {:error, _reason} ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
    |> halt()
  end
end

