defmodule EchoWeb.RequestJSON do
  alias Echo.Requests.Request

  @doc """
  Renders a list of requests.
  """
  def index(%{requests: requests}) do
    %{data: for(request <- requests, do: data(request))}
  end

  @doc """
  Renders a single request.
  """
  def show(%{request: request}) do
    data(request)
  end

  defp data(%Request{} = request) do
    body =
      case {request.content_type, request.body} do
        {_, ""} -> nil
        {"application/json" <> _, body} -> Jason.decode!(body)
        {_, body} -> body
      end

    headers =
      case request.headers do
        "" -> []
        _ -> Jason.decode!(request.headers)
      end

    url_query =
      case request.url_query do
        "" -> []
        _ -> Jason.decode!(request.url_query)
      end

    %{
      id: request.id,
      url_path: request.url_path,
      method: request.method,
      content_type: request.content_type,
      body: body,
      headers: headers,
      url_query: url_query
    }
  end
end
