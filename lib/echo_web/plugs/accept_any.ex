defmodule EchoWeb.Plugs.AcceptAny do
  @moduledoc """
  A plug that accepts any content type and sets the format to JSON for rendering.
  This bypasses Phoenix's content negotiation for the echo endpoints.
  """

  import Phoenix.Controller, only: [put_format: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    # Always set format to JSON so we can render responses
    conn
    |> put_format("json")
  end
end