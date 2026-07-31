defmodule EchoWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by tests that require setting up
  a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint EchoWeb.Endpoint

      use EchoWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import EchoWeb.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Echo.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Registers a token with Echo.AuthUser and attaches it as a bearer token."
  def authenticate(conn) do
    token = "test-token-#{System.unique_integer([:positive])}"
    :ok = Echo.AuthUser.login(token, 600)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end
end
