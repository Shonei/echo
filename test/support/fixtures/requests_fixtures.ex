defmodule Echo.RequestsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Echo.Requests` context.
  """

  @doc """
  Generate a request.
  """
  def request_fixture(attrs \\ %{}) do
    {:ok, request} =
      attrs
      |> Enum.into(%{
        body: "some body",
        content_type: "some content_type",
        headers: "some headers",
        method: "some method",
        url_path: "some url_path",
        url_query: "some url_query"
      })
      |> Echo.Requests.create_request()

    request
  end
end
