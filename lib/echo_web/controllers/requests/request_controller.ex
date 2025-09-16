defmodule EchoWeb.RequestController do
  use EchoWeb, :controller

  alias Echo.Requests
  alias Echo.Requests.Request

  action_fallback EchoWeb.FallbackController

  def any(conn, _params) do
    # Extract request data from the connection
    request_data = %{
      url_path: conn.request_path,
      method: conn.method,
      content_type: get_content_type(conn),
      body: get_request_body(conn),
      headers: serialize_headers(conn.req_headers),
      url_query: serialize_query_string(conn.query_string)
    }

    # Store the request in the database
    case Requests.create_request(request_data) do
      {:ok, %Request{} = request} ->
        # Return the stored request data as JSON
        conn
        |> put_status(:ok)
        |> render(:show, request: request)

      {:error, changeset} ->
        # This will be handled by the fallback controller
        {:error, changeset}
    end
  end

  # Helper functions
  defp get_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _] -> content_type
      [] -> "application/octet-stream"
    end
  end

  defp get_request_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        # Body hasn't been read yet, read it from assigns or return empty
        Map.get(conn.assigns, :raw_body, "")

      body_params when is_map(body_params) ->
        # Convert body params to JSON string
        Jason.encode!(body_params)

      _ ->
        ""
    end
  end

  # create a json like this %{:header, [values]}
  defp serialize_headers(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.update(acc, key, [value], fn existing -> existing ++ [value] end)
    end)
    |> Jason.encode!()
  end

  defp serialize_query_string(""), do: ""

  defp serialize_query_string(query_string) do
    query_string
    |> URI.decode_query()
    |> Jason.encode!()
  end
end
