defmodule EchoWeb.AssetController do
  use EchoWeb, :controller

  alias Echo.Storage.Assets
  require Logger

  @doc """
  GET /api/v1/assets

  Returns a list of all assets with optional filtering.
  Query params: reference_type, reference_id
  """
  def index(conn, params) do
    opts =
      []
      |> maybe_add_opt(:reference_type, Map.get(params, "reference_type"))
      |> maybe_add_opt(:reference_id, parse_integer(Map.get(params, "reference_id")))

    assets = Assets.list_assets(opts)

    conn
    |> put_status(:ok)
    |> json(%{
      data:
        Enum.map(assets, fn asset ->
          %{
            id: asset.id,
            name: asset.name,
            url_suffix: asset.url_suffix,
            content_type: asset.content_type,
            reference_type: asset.reference_type,
            reference_id: asset.reference_id,
            inserted_at: asset.inserted_at
          }
        end)
    })
  end

  @doc """
  GET /api/v1/assets/*path

  Returns the asset with correct content type and CDN caching headers.
  """
  def show(conn, %{"path" => path_parts}) do
    path = Enum.join(path_parts, "/")

    case Assets.get_asset_content(path) do
      {:ok, body, content_type} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("content-disposition", content_disposition(content_type, path))
        |> send_resp(200, body)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Asset not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to retrieve asset: #{inspect(reason)}"})
    end
  end

  @doc """
  PUT /api/v1/assets/*path

  Uploads an asset. Content type is determined from file extension.
  Optional query params: reference_type, reference_id
  """
  def update(conn, %{"path" => path_parts} = params) do
    path = Enum.join(path_parts, "/")
    content_type = content_type_from_extension(path)

    Logger.info("Uploading asset: #{path} with content type: #{content_type}")

    # Read raw body
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Parse optional reference params
    reference_type = Map.get(params, "reference_type")

    reference_id =
      case Map.get(params, "reference_id") do
        nil ->
          nil

        id when is_binary(id) ->
          case Integer.parse(id) do
            {int_id, ""} -> int_id
            _ -> :invalid
          end

        id when is_integer(id) ->
          id
      end

    if reference_id == :invalid do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "reference_id must be a valid integer"})
    else
      opts =
        []
        |> maybe_add_opt(:reference_type, reference_type)
        |> maybe_add_opt(:reference_id, reference_id)

      case Assets.upload_asset(path, body, content_type, opts) do
        {:ok, assets} when is_list(assets) ->
          conn
          |> put_status(:ok)
          |> json(%{
            data:
              Enum.map(assets, fn asset ->
                %{
                  id: asset.id,
                  name: asset.name,
                  url_suffix: asset.url_suffix,
                  content_type: asset.content_type,
                  reference_type: asset.reference_type,
                  reference_id: asset.reference_id
                }
              end)
          })

        {:error, :already_exists} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "Asset already exists. Duplicate upload detected."})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: format_changeset_errors(changeset)})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to upload asset: #{inspect(reason)}"})
      end
    end
  end

  # Determine content type from file extension
  defp content_type_from_extension(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".ico" -> "image/x-icon"
      ".pdf" -> "application/pdf"
      ".json" -> "application/json"
      ".html" -> "text/html"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".xml" -> "application/xml"
      ".zip" -> "application/zip"
      ".mp3" -> "audio/mpeg"
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      ".woff" -> "font/woff"
      ".woff2" -> "font/woff2"
      ".ttf" -> "font/ttf"
      ".otf" -> "font/otf"
      _ -> "application/octet-stream"
    end
  end

  # For images, show inline; for others, suggest download
  defp content_disposition(content_type, path) do
    filename = Path.basename(path)

    if String.starts_with?(content_type, "image/") do
      "inline; filename=\"#{filename}\""
    else
      "attachment; filename=\"#{filename}\""
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(value) when is_binary(value), do: String.to_integer(value)

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
