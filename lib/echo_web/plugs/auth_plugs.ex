defmodule EchoWeb.Plugs.BearerToken do
  @moduledoc """
  Shared token extraction for the API auth plugs.

  The token is read from the `Authorization` header on every request and is
  deliberately never written to the session: promoting it to a cookie would turn
  a short-lived API credential into a long-lived browser one, readable by anyone
  who can read the (signed, unencrypted) session cookie.
  """

  import Plug.Conn

  @doc "Returns `:ok` when the request carries a valid bearer token."
  def validate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Echo.AuthUser.validate_token(token)
      _ -> {:error, :unauthorized}
    end
  end
end

defmodule EchoWeb.Plugs.ValidateToken do
  @moduledoc """
  Requires a valid bearer token, halting with 401 otherwise.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias EchoWeb.Plugs.BearerToken

  def init(opts), do: opts

  def call(conn, _opts) do
    case BearerToken.validate(conn) do
      :ok ->
        assign(conn, :authenticated?, true)

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized"})
        |> halt()
    end
  end
end

defmodule EchoWeb.Plugs.MaybeAuthenticate do
  @moduledoc """
  Records whether the request is authenticated without requiring it.

  Used by endpoints that anyone may call but that reveal more to an editor, such
  as the blog reads: anonymous callers see only public blogs.
  """
  import Plug.Conn

  alias EchoWeb.Plugs.BearerToken

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :authenticated?, BearerToken.validate(conn) == :ok)
  end
end
