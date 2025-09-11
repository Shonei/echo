defmodule EchoWeb.RequestControllerTest do
  use EchoWeb.ConnCase

  import Echo.RequestsFixtures

  alias Echo.Requests.Request

  @create_attrs %{
    body: "some body",
    headers: "some headers",
    url_path: "some url_path",
    method: "some method",
    content_type: "some content_type",
    url_query: "some url_query"
  }
  @update_attrs %{
    body: "some updated body",
    headers: "some updated headers",
    url_path: "some updated url_path",
    method: "some updated method",
    content_type: "some updated content_type",
    url_query: "some updated url_query"
  }
  @invalid_attrs %{body: nil, headers: nil, url_path: nil, method: nil, content_type: nil, url_query: nil}

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all requests", %{conn: conn} do
      conn = get(conn, ~p"/api/requests")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create request" do
    test "renders request when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/requests", request: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/requests/#{id}")

      assert %{
               "id" => ^id,
               "body" => "some body",
               "content_type" => "some content_type",
               "headers" => "some headers",
               "method" => "some method",
               "url_path" => "some url_path",
               "url_query" => "some url_query"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/requests", request: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update request" do
    setup [:create_request]

    test "renders request when data is valid", %{conn: conn, request: %Request{id: id} = request} do
      conn = put(conn, ~p"/api/requests/#{request}", request: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/requests/#{id}")

      assert %{
               "id" => ^id,
               "body" => "some updated body",
               "content_type" => "some updated content_type",
               "headers" => "some updated headers",
               "method" => "some updated method",
               "url_path" => "some updated url_path",
               "url_query" => "some updated url_query"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, request: request} do
      conn = put(conn, ~p"/api/requests/#{request}", request: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete request" do
    setup [:create_request]

    test "deletes chosen request", %{conn: conn, request: request} do
      conn = delete(conn, ~p"/api/requests/#{request}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/api/requests/#{request}")
      end
    end
  end

  describe "any request" do
    test "stores request and returns same data", %{conn: conn} do
      # Make a POST request to /echo/test with some data
      conn = conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-custom-header", "test-value")
        |> post("/echo/test?param=value", %{"key" => "value"})

      # Should return 200 OK
      assert response = json_response(conn, 200)
      assert %{"data" => data} = response

      # Verify the returned data contains the request information
      assert data["url_path"] == "/echo/test"
      assert data["method"] == "POST"
      assert data["content_type"] == "application/json"
      assert String.contains?(data["headers"], "content-type: application/json")
      assert String.contains?(data["headers"], "x-custom-header: test-value")
      assert data["url_query"] == "param=value"
      assert data["body"] != nil
      assert data["id"] != nil
    end

    test "handles GET request with query parameters", %{conn: conn} do
      conn = get(conn, "/echo/api/users?id=123&name=test")

      assert response = json_response(conn, 200)
      assert %{"data" => data} = response

      assert data["url_path"] == "/echo/api/users"
      assert data["method"] == "GET"
      assert data["url_query"] == "id=123&name=test"
    end
  end

  defp create_request(_) do
    request = request_fixture()
    %{request: request}
  end
end
