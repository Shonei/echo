defmodule EchoWeb.LoginController do
  use EchoWeb, :controller

  # 8 hours
  @ttl 8 * 60 * 60

  def create(conn, params) do
    case Application.fetch_env(:echo, :auth) do
      {:ok, auth_config} ->
        handle_login(conn, params, auth_config)

      :error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Auth not configured"})
    end
  end

  defp handle_login(conn, params, auth_config) do
    # Support both JSON body and Basic Auth as per standard practices,
    # though prompt mentioned "where the basic auth is submitted".
    # We'll check Basic Auth header first, then params.

    expected_username = auth_config[:username]
    expected_password = auth_config[:password]

    case get_credentials(conn, params) do
      {u, p} when u == expected_username and p == expected_password ->
        # Generate Token
        signer = Joken.Signer.create("HS256", auth_config[:secret])
        {:ok, token, _claims} = Joken.generate_and_sign(%{}, signer)

        # Store in AuthUser
        Echo.AuthUser.login(token, @ttl)

        conn
        |> put_status(:ok)
        |> json(%{accessToken: token, ttl: @ttl})

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid credentials"})
    end
  end

  defp get_credentials(conn, params) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Basic " <> encoded] ->
        case Base.decode64(encoded) do
          {:ok, decoded} ->
            case String.split(decoded, ":", parts: 2) do
              [u, p] -> {u, p}
              _ -> {nil, nil}
            end

          _ ->
            {nil, nil}
        end

      _ ->
        {params["username"], params["password"]}
    end
  end
end
