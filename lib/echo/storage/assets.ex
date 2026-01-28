defmodule Echo.Storage.Assets do
  @moduledoc """
  Context for managing assets stored in S3.

  Provides functions to upload, retrieve, and manage assets with their metadata
  stored in the database.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo
  alias Echo.Storage.Asset
  alias Echo.Storage.S3Client
  alias Vix.Vips.{Image, Operation}
  require Logger

  @doc """
  Gets an asset by its storage path.

  Returns `nil` if no asset is found.
  """
  def get_asset_by_path(path) do
    url_pattern = "%/#{path}"

    Asset
    |> where([a], like(a.url, ^url_pattern))
    |> Repo.one()
  end

  @doc """
  Gets an asset by ID.
  """
  def get_asset!(id), do: Repo.get!(Asset, id)

  @doc """
  Gets an asset by ID, returns nil if not found.
  """
  def get_asset(id), do: Repo.get(Asset, id)

  @doc """
  Lists assets, optionally filtered by reference.
  """
  def list_assets(opts \\ []) do
    query = from(a in Asset, order_by: [desc: a.inserted_at])

    query =
      case Keyword.get(opts, :reference_type) do
        nil -> query
        type -> where(query, [a], a.reference_type == ^type)
      end

    query =
      case Keyword.get(opts, :reference_id) do
        nil -> query
        id -> where(query, [a], a.reference_id == ^id)
      end

    Repo.all(query)
  end

  @doc """
  Creates an asset record in the database.
  """
  def create_asset(attrs) do
    %Asset{}
    |> Asset.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes an asset from both the database and S3 storage.
  """
  def delete_asset(%Asset{} = asset) do
    # Extract path from URL for S3 deletion
    path = extract_path_from_url(asset.url)

    case S3Client.delete_object(path) do
      :ok ->
        Repo.delete(asset)

      {:error, :not_found} ->
        # Object already gone from S3, just delete DB record
        Repo.delete(asset)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Uploads a file to S3 and creates a database record.

  Returns `{:ok, asset}` on success or `{:error, reason}` on failure.
  """
  def upload_asset(path, body, content_type, opts \\ []) do
    reference_type = Keyword.get(opts, :reference_type)
    reference_id = Keyword.get(opts, :reference_id)

    # Check if asset already exists with this path
    case get_asset_by_path(path) do
      nil ->
        do_upload_asset(path, body, content_type, reference_type, reference_id)

      existing_asset ->
        Logger.info("Existing asset: #{inspect(existing_asset)}")

        # Reject if references don't match to prevent accidental overwrites
        if references_match?(existing_asset, reference_type, reference_id) do
          do_upload_asset(path, body, content_type, reference_type, reference_id, existing_asset)
        else
          {:error, :reference_mismatch}
        end
    end
  end

  defp references_match?(asset, reference_type, reference_id) do
    asset.reference_type == reference_type and asset.reference_id == reference_id
  end

  defp do_upload_asset(
         path,
         body,
         content_type,
         reference_type,
         reference_id,
         existing_asset \\ nil
       ) do
    case upload_to_s3(path, body, content_type) do
      :ok ->
        url = build_asset_url(path)
        url_suffix = build_url_suffix(path)

        attrs = %{
          name: path,
          url: url,
          url_suffix: url_suffix,
          content_type: content_type,
          reference_type: reference_type,
          reference_id: reference_id
        }

        if existing_asset do
          existing_asset
          |> Asset.changeset(attrs)
          |> Repo.update()
        else
          create_asset(attrs)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_to_s3(path, body, content_type) do
    case content_type do
      "image/" <> _ ->
        case make_thumbnail_for_image(body) do
          {:ok, thumbnail} ->
            result = S3Client.upload_object("#{path}_thumbnail", thumbnail, "image/jpeg")
            Logger.info("Thumbnail upload result: #{inspect(result)}")

          {:error, reason} ->
            {:error, reason}
        end
    end

    case S3Client.upload_object(path, body, content_type) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets the content of an asset from S3.

  Returns `{:ok, body, content_type}` on success or `{:error, reason}` on failure.
  """
  def get_asset_content(path) do
    case S3Client.get_object(path) do
      {:ok, body, content_type} ->
        {:ok, body, content_type}

      {:error, :not_found} ->
        # If this is the thumbnail path, try to get the original
        if String.ends_with?(path, "_thumbnail") do
          get_asset_content(String.replace_suffix(path, "_thumbnail", ""))
        else
          {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  # make a thumbnail for an image and return it as a jpeg
  # returns {:ok, buffer} or {:error, reason}
  defp make_thumbnail_for_image(body) do
    with {:ok, thumbnail} <- Operation.thumbnail_buffer(body, 300),
         {:ok, buffer} <- Image.write_to_buffer(thumbnail, ".jpeg") do
      {:ok, buffer}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_asset_url(path) do
    config = Application.get_env(:echo, Echo.Storage.S3Client, [])
    endpoint = Keyword.get(config, :endpoint, "")
    bucket = Keyword.get(config, :bucket, "")
    "#{endpoint}/#{bucket}/#{path}"
  end

  # make sure path starts with /
  defp build_url_suffix(path) do
    if String.starts_with?(path, "/") do
      path
    else
      "/#{path}"
    end
  end

  defp extract_path_from_url(url) do
    config = Application.get_env(:echo, Echo.Storage.S3Client, [])
    bucket = Keyword.get(config, :bucket, "")
    # Remove endpoint and bucket from URL to get the path
    url
    |> String.split("/#{bucket}/", parts: 2)
    |> List.last()
  end
end
