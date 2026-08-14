defmodule EchoWeb.AssetControllerTest do
  use EchoWeb.ConnCase, async: true

  alias Echo.Storage.Assets

  test "index includes file metadata", %{conn: conn} do
    path = "docs/notes-#{System.unique_integer([:positive])}.txt"

    {:ok, asset} =
      Assets.create_asset(%{
        name: path,
        url: "https://example.com/bucket/#{path}",
        url_suffix: "/#{path}",
        content_type: "text/plain",
        filename: "notes.txt",
        byte_size: 42,
        variant: "original",
        content_hash: "deadbeef"
      })

    response = json_response(get(conn, "/api/v1/assets"), 200)
    listed = Enum.find(response["data"], &(&1["id"] == asset.id))

    assert listed["filename"] == "notes.txt"
    assert listed["byte_size"] == 42
    assert listed["width"] == nil
    assert listed["height"] == nil
    assert listed["variant"] == "original"
    assert listed["content_hash"] == "deadbeef"
  end
end
