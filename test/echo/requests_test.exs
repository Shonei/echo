defmodule Echo.RequestsTest do
  use Echo.DataCase

  alias Echo.Requests

  describe "requests" do
    alias Echo.Requests.Request

    import Echo.RequestsFixtures

    @invalid_attrs %{body: nil, headers: nil, url_path: nil, method: nil, content_type: nil, url_query: nil}

    test "list_requests/0 returns all requests" do
      request = request_fixture()
      assert Requests.list_requests() == [request]
    end

    test "get_request!/1 returns the request with given id" do
      request = request_fixture()
      assert Requests.get_request!(request.id) == request
    end

    test "create_request/1 with valid data creates a request" do
      valid_attrs = %{body: "some body", headers: "some headers", url_path: "some url_path", method: "some method", content_type: "some content_type", url_query: "some url_query"}

      assert {:ok, %Request{} = request} = Requests.create_request(valid_attrs)
      assert request.body == "some body"
      assert request.headers == "some headers"
      assert request.url_path == "some url_path"
      assert request.method == "some method"
      assert request.content_type == "some content_type"
      assert request.url_query == "some url_query"
    end

    test "create_request/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Requests.create_request(@invalid_attrs)
    end

    test "update_request/2 with valid data updates the request" do
      request = request_fixture()
      update_attrs = %{body: "some updated body", headers: "some updated headers", url_path: "some updated url_path", method: "some updated method", content_type: "some updated content_type", url_query: "some updated url_query"}

      assert {:ok, %Request{} = request} = Requests.update_request(request, update_attrs)
      assert request.body == "some updated body"
      assert request.headers == "some updated headers"
      assert request.url_path == "some updated url_path"
      assert request.method == "some updated method"
      assert request.content_type == "some updated content_type"
      assert request.url_query == "some updated url_query"
    end

    test "update_request/2 with invalid data returns error changeset" do
      request = request_fixture()
      assert {:error, %Ecto.Changeset{}} = Requests.update_request(request, @invalid_attrs)
      assert request == Requests.get_request!(request.id)
    end

    test "delete_request/1 deletes the request" do
      request = request_fixture()
      assert {:ok, %Request{}} = Requests.delete_request(request)
      assert_raise Ecto.NoResultsError, fn -> Requests.get_request!(request.id) end
    end

    test "change_request/1 returns a request changeset" do
      request = request_fixture()
      assert %Ecto.Changeset{} = Requests.change_request(request)
    end

    test "search_requests/1 filters by url_path" do
      request1 = request_fixture(%{url_path: "/api/users", method: "GET"})
      request2 = request_fixture(%{url_path: "/api/posts", method: "GET"})

      results = Requests.search_requests(%{url_path: "/api/users"})
      assert length(results) == 1
      assert hd(results).id == request1.id
    end

    test "search_requests/1 filters by method" do
      request1 = request_fixture(%{url_path: "/api/test", method: "GET"})
      request2 = request_fixture(%{url_path: "/api/test", method: "POST"})

      results = Requests.search_requests(%{method: "POST"})
      assert length(results) == 1
      assert hd(results).id == request2.id
    end

    test "search_requests/1 filters by path and method combined" do
      request1 = request_fixture(%{url_path: "/api/users", method: "GET"})
      request2 = request_fixture(%{url_path: "/api/users", method: "POST"})
      request3 = request_fixture(%{url_path: "/api/posts", method: "GET"})

      results = Requests.search_requests(%{url_path: "/api/users", method: "GET"})
      assert length(results) == 1
      assert hd(results).id == request1.id
    end

    test "search_requests/1 filters by query parameter content" do
      request1 = request_fixture(%{url_query: Jason.encode!(%{"user_id" => "123"})})
      request2 = request_fixture(%{url_query: Jason.encode!(%{"post_id" => "456"})})

      results = Requests.search_requests(%{query_contains: "user_id"})
      assert length(results) == 1
      assert hd(results).id == request1.id
    end
  end
end
