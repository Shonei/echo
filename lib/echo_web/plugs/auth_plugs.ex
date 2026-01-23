defmodule EchoWeb.Plugs.ExtractToken do
  @moduledoc """
  Extracts the token from the Authorization header and stores it in the session.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        put_session(conn, :user_token, token)

      _ ->
        # No token or invalid format, proceed without token in session
        # or keep existing if any (though typically this is per request)
        conn
    end
  end
end

defmodule EchoWeb.Plugs.ValidateToken do
  @moduledoc """
  Validates the token from the session using Echo.AuthUser.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :user_token) do
      nil ->
        unauthorized(conn)

      token ->
        case Echo.AuthUser.validate_token(token) do
          :ok ->
            conn

          {:error, :unauthorized} ->
            unauthorized(conn)
        end
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized"})
    |> halt()
  end
end
