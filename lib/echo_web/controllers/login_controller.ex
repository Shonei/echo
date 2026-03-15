defmodule EchoWeb.LoginController do
  use EchoWeb, :controller

  # 8 hours
  @ttl 8 * 60 * 60

  def create(conn, params) do
    auth_config = Application.fetch_env!(:echo, :auth)
    handle_login(conn, params, auth_config)
  end

  defp handle_login(conn, params, auth_config) do
    expected_username = Keyword.fetch!(auth_config, :username)
    expected_password = Keyword.fetch!(auth_config, :password)

    case get_credentials(conn, params) do
      {u, p} when u == expected_username and p == expected_password ->
        # Generate Token
        signer = Joken.Signer.create("HS256", auth_config[:secret])

        case Joken.generate_and_sign(
               %{},
               %{
                 "exp" =>
                   DateTime.utc_now() |> DateTime.add(@ttl, :second) |> DateTime.to_iso8601()
               },
               signer
             ) do
          {:ok, token, _claims} ->
            # Store in AuthUser
            Echo.AuthUser.login(token, @ttl)

            conn
            |> put_status(:ok)
            |> json(%{accessToken: token, ttl: @ttl})

          _ ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to generate token"})
        end

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
