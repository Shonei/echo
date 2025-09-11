defmodule EchoWeb.UIController do
  use EchoWeb, :controller

  alias Echo.Requests

  def requests(conn, params) do
    # Get pagination parameters
    page = Map.get(params, "page", "1") |> String.to_integer()
    per_page = 20
    offset = (page - 1) * per_page

    # Get filter parameters
    filters = build_filters(params)

    # Get requests with pagination
    requests = 
      if Enum.empty?(filters) do
        Requests.list_requests()
      else
        Requests.search_requests(filters)
      end
      |> Enum.sort_by(& &1.inserted_at, :desc)
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    # Get total count for pagination
    total_count = 
      if Enum.empty?(filters) do
        Requests.count_requests()
      else
        Requests.search_requests(filters) |> length()
      end

    total_pages = ceil(total_count / per_page)

    render(conn, :requests, 
      requests: requests, 
      current_page: page, 
      total_pages: total_pages,
      filters: params
    )
  end

  def request_detail(conn, %{"id" => id}) do
    request = Requests.get_request!(id)
    render(conn, :request_detail, request: request)
  end

  defp build_filters(params) do
    filters = %{}

    filters = 
      case Map.get(params, "method") do
        method when method != nil and method != "" -> Map.put(filters, :method, method)
        _ -> filters
      end

    filters = 
      case Map.get(params, "url_path") do
        path when path != nil and path != "" -> Map.put(filters, :url_path_like, "%#{path}%")
        _ -> filters
      end

    filters = 
      case Map.get(params, "content_type") do
        content_type when content_type != nil and content_type != "" -> 
          Map.put(filters, :content_type, content_type)
        _ -> filters
      end

    filters
  end
end
