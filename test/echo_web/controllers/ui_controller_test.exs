defmodule EchoWeb.UIControllerTest do
  use EchoWeb.ConnCase

  import Echo.RequestsFixtures

  describe "requests" do
    test "lists all requests", %{conn: conn} do
      request = request_fixture()
      conn = get(conn, ~p"/ui/request")
      assert html_response(conn, 200) =~ "Request History"
      assert html_response(conn, 200) =~ request.method
      assert html_response(conn, 200) =~ request.url_path
    end

    test "filters requests by method", %{conn: conn} do
      get_request = request_fixture(%{method: "GET", url_path: "/api/test"})
      post_request = request_fixture(%{method: "POST", url_path: "/api/test"})

      conn = get(conn, ~p"/ui/request?method=GET")
      response = html_response(conn, 200)
      
      assert response =~ get_request.method
      refute response =~ post_request.method
    end

    test "filters requests by url_path", %{conn: conn} do
      users_request = request_fixture(%{url_path: "/api/users", method: "GET"})
      posts_request = request_fixture(%{url_path: "/api/posts", method: "GET"})

      conn = get(conn, ~p"/ui/request?url_path=users")
      response = html_response(conn, 200)
      
      assert response =~ users_request.url_path
      refute response =~ posts_request.url_path
    end

    test "shows pagination when there are many requests", %{conn: conn} do
      # Create more than 20 requests to trigger pagination
      for i <- 1..25 do
        request_fixture(%{url_path: "/api/test/#{i}", method: "GET"})
      end

      conn = get(conn, ~p"/ui/request")
      response = html_response(conn, 200)
      
      assert response =~ "Page"
      assert response =~ "Next"
    end
  end

  describe "request_detail" do
    test "shows request details", %{conn: conn} do
      request = request_fixture(%{
        method: "POST",
        url_path: "/api/users",
        content_type: "application/json",
        body: Jason.encode!(%{name: "John", email: "john@example.com"}),
        headers: Jason.encode!([%{key: "content-type", value: "application/json"}])
      })

      conn = get(conn, ~p"/ui/request/#{request.id}")
      response = html_response(conn, 200)
      
      assert response =~ "Request Details"
      assert response =~ request.method
      assert response =~ request.url_path
      assert response =~ request.content_type
      assert response =~ "John"
      assert response =~ "john@example.com"
    end

    test "shows back to requests link", %{conn: conn} do
      request = request_fixture()
      conn = get(conn, ~p"/ui/request/#{request.id}")
      response = html_response(conn, 200)
      
      assert response =~ "Back to Requests"
      assert response =~ ~p"/ui/request"
    end

    test "returns 404 for non-existent request", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/ui/request/999999")
      end
    end
  end
end
