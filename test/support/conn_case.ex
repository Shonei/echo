defmodule EchoWeb.ConnCase do
  @moduledoc """
  Setup for HTTP/JSON contract tests.

  Arrange with fixtures (`blog_fixture/1`), act through the router, assert on
  status and the JSON body. Seed unique fields with `unique/1`. The database is
  long-lived: look up this test's row, do not assume an empty index.
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
      import Echo.ContentFixtures
      import Echo.SkillsFixtures
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
