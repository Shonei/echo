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

  def create(conn, %{"upload" => %Plug.Upload{} = upload, "password" => password}) do
    if verify_password?(password) do
      # Read the file content
      {:ok, body} = File.read(upload.path)

      # Simple content type resolution
      content_type = content_type_from_filename(upload.filename)

      # Use filename as path but we can also organize them under an "uploads/" prefix
      path = "uploads/#{System.unique_integer([:positive])}-#{upload.filename}"

      case Assets.upload_asset(path, body, content_type, []) do
        {:ok, _assets} ->
          conn
          |> put_flash(:info, "Asset uploaded successfully.")
          |> redirect(to: ~p"/assets")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Failed to upload asset.")
          |> redirect(to: ~p"/assets")
      end
    else
      conn
      |> put_flash(:error, "Invalid password.")
      |> redirect(to: ~p"/assets")
    end
  end

  def create(conn, %{"password" => _password}) do
    conn
    |> put_flash(:error, "No file provided.")
    |> redirect(to: ~p"/assets")
  end

  def delete(conn, %{"id" => id, "password" => password}) do
    if verify_password?(password) do
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
    else
      conn
      |> put_flash(:error, "Invalid password.")
      |> redirect(to: ~p"/assets")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:error, "Password required to delete assets.")
    |> redirect(to: ~p"/assets")
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

  defp verify_password?(password) do
    configured_password =
      case Application.get_env(:echo, :auth) do
        nil -> System.get_env("BLOGS_PASSWORD")
        auth -> Keyword.get(auth, :password) || System.get_env("BLOGS_PASSWORD")
      end

    # If no password is required by the system, allow it
    if is_nil(configured_password) do
      true
    else
      Plug.Crypto.secure_compare(password, configured_password)
    end
  end
end
