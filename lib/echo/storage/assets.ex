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

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    query =
      case Keyword.get(opts, :offset) do
        nil -> query
        offset -> offset(query, ^offset)
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
    # For generated images, we might have multiple assets with the same original_hash
    # We should only delete from S3 if this is the last asset referencing that S3 object
    # For now, delete it from S3 regardless since generating images again will re-create it.

    # We use name as path in S3 because url_suffix has a leading slash
    path = asset.name

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
  Uploads a file to S3 and creates database records.
  If the file is an image, it generates and stores 4 versions: original, background, content, and thumbnail.

  Returns `{:ok, [assets]}` on success or `{:error, reason}` on failure.
  """
  def upload_asset(path, body, content_type, opts \\ []) do
    reference_type = Keyword.get(opts, :reference_type)
    reference_id = Keyword.get(opts, :reference_id)

    if String.starts_with?(content_type, "image/") do
      handle_image_upload(path, body, content_type, reference_type, reference_id)
    else
      handle_regular_upload(path, body, content_type, reference_type, reference_id)
    end
  end

  defp handle_regular_upload(path, body, content_type, reference_type, reference_id) do
    hash = compute_hash(path, content_type, reference_type, reference_id)

    if asset_exists_by_hash?(hash) do
      {:error, :already_exists}
    else
      case S3Client.upload_object(path, body, content_type) do
        :ok ->
          case create_asset_record(path, content_type, hash, reference_type, reference_id) do
            {:ok, asset} -> {:ok, [asset]}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_image_upload(path, body, content_type, reference_type, reference_id) do
    ext = Path.extname(path)
    base = String.replace_suffix(path, ext, "")

    # Default to .jpeg if there is no extension or if it's not well defined in path
    ext = if ext == "", do: ".jpeg", else: ext

    base_sizes = [
      {:original, base <> "-original" <> ext, nil, ext},
      {:background, base <> "-background" <> ext, 1920, ext},
      {:content, base <> "-content" <> ext, 800, ext},
      {:thumbnail, base <> "-thumbnail.jpeg", 400, ".jpeg"}
    ]

    # Generate images first
    generated_images =
      Enum.map(base_sizes, fn {type, current_path, width, target_ext} ->
        processed_body =
          if type == :original do
            body
          else
            process_image(body, width, target_ext)
          end

        current_content_type =
          if target_ext in [".jpeg", ".jpg"], do: "image/jpeg", else: content_type

        hash = compute_hash(current_path, current_content_type, reference_type, reference_id)

        %{
          path: current_path,
          body: processed_body,
          content_type: current_content_type,
          hash: hash
        }
      end)

    # Check for processing errors
    processing_error =
      Enum.find(generated_images, fn img ->
        case img.body do
          {:error, _} -> true
          _ -> false
        end
      end)

    if processing_error do
      {:error, {:image_processing_failed, elem(processing_error.body, 1)}}
    else
      # Check if ANY image hash already exists
      hashes = Enum.map(generated_images, & &1.hash)

      if any_asset_exists_by_hashes?(hashes) do
        {:error, :already_exists}
      else
        # First upload all images
        upload_result =
          Enum.reduce_while(generated_images, :ok, fn img, _acc ->
            case S3Client.upload_object(img.path, img.body, img.content_type) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case upload_result do
          :ok ->
            # After, update the DB in a transaction
            case Repo.transaction(fn ->
                   Enum.map(generated_images, fn img ->
                     create_asset_record!(
                       img.path,
                       img.content_type,
                       img.hash,
                       reference_type,
                       reference_id
                     )
                   end)
                 end) do
              {:ok, assets} -> {:ok, assets}
              {:error, {:db_insert_failed, changeset}} -> {:error, changeset}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, {:s3_upload_failed, reason}}
        end
      end
    end
  end

  defp compute_hash(path, content_type, reference_type, reference_id) do
    ref_type_str = if reference_type, do: to_string(reference_type), else: "nil"
    ref_id_str = if reference_id, do: to_string(reference_id), else: "nil"

    :crypto.hash(:sha256, "#{content_type}+#{path}+#{ref_type_str}+#{ref_id_str}")
    |> Base.encode16(case: :lower)
  end

  defp asset_exists_by_hash?(hash) do
    Asset
    |> where([a], a.original_hash == ^hash)
    |> Repo.exists?()
  end

  defp any_asset_exists_by_hashes?(hashes) do
    Asset
    |> where([a], a.original_hash in ^hashes)
    |> Repo.exists?()
  end

  defp create_asset_record(path, content_type, original_hash, reference_type, reference_id) do
    url = build_asset_url(path)
    url_suffix = build_url_suffix(path)

    attrs = %{
      name: path,
      url: url,
      url_suffix: url_suffix,
      content_type: content_type,
      reference_type: reference_type,
      reference_id: reference_id,
      original_hash: original_hash
    }

    create_asset(attrs)
  end

  defp create_asset_record!(path, content_type, original_hash, reference_type, reference_id) do
    case create_asset_record(path, content_type, original_hash, reference_type, reference_id) do
      {:ok, asset} -> asset
      {:error, changeset} -> Repo.rollback({:db_insert_failed, changeset})
    end
  end

  # Gets the content of an asset from S3.
  #
  # Returns `{:ok, body, content_type}` on success or `{:error, reason}` on failure.
  def get_asset_content(path) do
    case S3Client.get_object(path) do
      {:ok, body, content_type} ->
        {:ok, body, content_type}

      {:error, :not_found} ->
        # We can no longer fall back to `_thumbnail` dynamically because we changed the path format.
        # It's better to explicitly request the correct suffixed route.
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  # Resize image and return binary
  defp process_image(body, width, target_ext) do
    :telemetry.span(
      [:echo, :storage, :image, :process],
      %{width: width, target_ext: target_ext},
      fn ->
        result =
          with {:ok, thumbnail} <- Operation.thumbnail_buffer(body, width),
               {:ok, buffer} <- Image.write_to_buffer(thumbnail, target_ext) do
            buffer
          else
            {:error, reason} -> {:error, reason}
          end

        {result, %{width: width, target_ext: target_ext}}
      end
    )
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
end
