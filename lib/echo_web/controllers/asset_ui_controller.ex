defmodule EchoWeb.AssetUIController do
  use EchoWeb, :controller

  alias Echo.Storage.Assets
  require Logger

  def index(conn, params) do
    page =
      case Map.get(params, "page") do
        nil -> 1
        page_str when is_binary(page_str) -> String.to_integer(page_str)
      end

    per_page = 20
    offset = (page - 1) * per_page

    # Fetch one extra to know if there's a next page
    assets = Assets.list_assets(limit: per_page + 1, offset: offset)

    has_more = length(assets) > per_page
    assets_to_show = Enum.take(assets, per_page)

    render(conn, :index, assets: assets_to_show, page: page, has_more: has_more)
  end

  def show(conn, %{"id" => id}) do
    case Assets.get_asset(id) do
      nil ->
        conn
        |> put_flash(:error, "Asset not found.")
        |> redirect(to: ~p"/assets")

      asset ->
        render(conn, :show, asset: asset)
    end
  end

  def create(conn, %{"upload" => %Plug.Upload{} = upload}) do
    # Read the file content
    {:ok, body} = File.read(upload.path)

    # Simple content type resolution
    content_type = content_type_from_filename(upload.filename)

    # Use filename as path but we can also organize them under an "uploads/" prefix
    path = "uploads/#{System.unique_integer([:positive])}-#{upload.filename}"

    case Assets.upload_asset(path, body, content_type, filename: upload.filename) do
      {:ok, _assets} ->
        conn
        |> put_flash(:info, "Asset uploaded successfully.")
        |> redirect(to: ~p"/assets")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to upload asset.")
        |> redirect(to: ~p"/assets")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "No file provided.")
    |> redirect(to: ~p"/assets")
  end

  def delete(conn, %{"id" => id}) do
    case Assets.get_asset(id) do
      nil ->
        conn
        |> put_flash(:error, "Asset not found.")
        |> redirect(to: ~p"/assets")

      asset ->
        case Assets.delete_asset(asset) do
          {:ok, _} ->
            conn
            |> put_flash(:info, "Asset deleted successfully.")
            |> redirect(to: ~p"/assets")

          {:error, _reason} ->
            conn
            |> put_flash(:error, "Failed to delete asset.")
            |> redirect(to: ~p"/assets")
        end
    end
  end

  defp content_type_from_filename(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".json" -> "application/json"
      ".csv" -> "text/csv"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".mp4" -> "video/mp4"
      ".mp3" -> "audio/mpeg"
      ".zip" -> "application/zip"
      _ -> "application/octet-stream"
    end
  end
end
