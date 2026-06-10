defmodule EchoWeb.Plugs.CacheRawBody do
  @moduledoc """
  Reads the raw request body and stores it in conn.assigns[:raw_body].
  Must run before anything else consumes the body. Used by the echo
  routes, which have no Plug.Parsers.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    {body, conn} = read_full_body(conn, "")
    Plug.Conn.assign(conn, :raw_body, body)
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {acc <> body, conn}
      {:more, body, conn} -> read_full_body(conn, acc <> body)
    end
  end
end
