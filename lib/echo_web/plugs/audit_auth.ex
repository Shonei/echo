defmodule EchoWeb.Plugs.AuditAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected_password = Application.get_env(:echo, :audit_password)

    if expected_password && expected_password != "" do
      verify_token(conn, expected_password)
    else
      conn
    end
  end

  defp verify_token(conn, expected_password) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token == expected_password ->
        conn

      _ ->
        conn
        |> send_resp(401, "Unauthorized")
        |> halt()
    end
  end
end
