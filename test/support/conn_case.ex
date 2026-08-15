defmodule EchoWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by tests that require setting up
  a connection.

  The database is shared and long-lived. Seed unique fields with `unique/1`
  from `Echo.DataCase`.
  """

  use ExUnit.CaseTemplate
  import Echo.DataCase, only: [unique: 1]

  using do
    quote do
      @endpoint EchoWeb.Endpoint

      use EchoWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Echo.DataCase
      import EchoWeb.ConnCase
    end
  end

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Registers a token with Echo.AuthUser and attaches it as a bearer token."
  def authenticate(conn) do
    token = unique("token")
    :ok = Echo.AuthUser.login(token, 600)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end
end
