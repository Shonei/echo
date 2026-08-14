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

  @doc """
  Gets an asset by its storage path.

  Returns `nil` if no asset is found.
  """
  def get_asset_by_path(path) do
    url_pattern = "%/#{path}"

    Asset
    # ilike, not like: SQLite's LIKE is case-insensitive for ASCII but Postgres'
    # is not, and this lookup backs asset deletion.
    |> where([a], ilike(a.url, ^url_pattern))
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

  If the file is an image, it generates and stores 4 versions: original,
  background, content, and thumbnail.

  Options:

    * `:filename` - original client filename. Defaults to the basename of `path`.
    * `:reference_type` / `:reference_id` - optional link to another resource
    * `:storage` - module with `upload_object/3`. Defaults to `S3Client`.

  Each stored file gets `filename`, `byte_size`, `variant`, `content_hash`,
  and for images `width` / `height`.

  Returns `{:ok, [assets]}` on success or `{:error, reason}` on failure.
  """
  def upload_asset(path, body, content_type, opts \\ []) do
    reference_type = Keyword.get(opts, :reference_type)
    reference_id = Keyword.get(opts, :reference_id)
    filename = Keyword.get(opts, :filename) || Path.basename(path)
    storage = Keyword.get(opts, :storage, S3Client)
    file_size_bytes = byte_size(body)

    :telemetry.span(
      [:echo, :storage, :asset, :upload],
      %{
        path: path,
        content_type: content_type,
        file_size_bytes: file_size_bytes,
        image?: String.starts_with?(content_type, "image/")
      },
      fn ->
        result =
          if String.starts_with?(content_type, "image/") do
            handle_image_upload(
              path,
              body,
              content_type,
              reference_type,
              reference_id,
              filename,
              storage
            )
          else
            handle_regular_upload(
              path,
              body,
              content_type,
              reference_type,
              reference_id,
              filename,
              storage
            )
          end

        {result, upload_span_metadata(path, content_type, file_size_bytes, result)}
      end
    )
  end

  defp upload_span_metadata(path, content_type, file_size_bytes, {:ok, assets}) do
    %{
      path: path,
      content_type: content_type,
      file_size_bytes: file_size_bytes,
      image?: String.starts_with?(content_type, "image/"),
      variant_count: length(assets),
      result: :ok
    }
  end

  defp upload_span_metadata(path, content_type, file_size_bytes, {:error, reason}) do
    %{
      path: path,
      content_type: content_type,
      file_size_bytes: file_size_bytes,
      image?: String.starts_with?(content_type, "image/"),
      result: :error,
      error: format_upload_error(reason)
    }
  end

  defp format_upload_error(:already_exists), do: "already_exists"

  defp format_upload_error({:image_processing_failed, reason}),
    do: "image_processing_failed: #{inspect(reason)}"

  defp format_upload_error({:s3_upload_failed, reason}),
    do: "s3_upload_failed: #{inspect(reason)}"

  defp format_upload_error(%Ecto.Changeset{} = changeset),
    do: "changeset: #{inspect(changeset.errors)}"

  defp format_upload_error(reason), do: inspect(reason)

  defp handle_regular_upload(
         path,
         body,
         content_type,
         reference_type,
         reference_id,
         filename,
         storage
       ) do
    hash = compute_hash(path, content_type, reference_type, reference_id)

    if asset_exists_by_hash?(hash) do
      {:error, :already_exists}
    else
      case storage.upload_object(path, body, content_type) do
        :ok ->
          case create_asset_record(%{
                 path: path,
                 content_type: content_type,
                 original_hash: hash,
                 reference_type: reference_type,
                 reference_id: reference_id,
                 filename: filename,
                 byte_size: byte_size(body),
                 width: nil,
                 height: nil,
                 variant: "original",
                 content_hash: content_hash(body)
               }) do
            {:ok, asset} -> {:ok, [asset]}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_image_upload(
         path,
         body,
         content_type,
         reference_type,
         reference_id,
         filename,
         storage
       ) do
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

    case generate_image_variants(
           base_sizes,
           body,
           content_type,
           reference_type,
           reference_id,
           filename
         ) do
      {:error, reason} ->
        {:error, {:image_processing_failed, reason}}

      {:ok, generated_images} ->
        hashes = Enum.map(generated_images, & &1.original_hash)

        if any_asset_exists_by_hashes?(hashes) do
          {:error, :already_exists}
        else
          upload_result =
            Enum.reduce_while(generated_images, :ok, fn img, _acc ->
              case storage.upload_object(img.path, img.body, img.content_type) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)

          case upload_result do
            :ok ->
              case Repo.transaction(fn ->
                     Enum.map(generated_images, &create_asset_record!/1)
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

  defp generate_image_variants(
         base_sizes,
         body,
         content_type,
         reference_type,
         reference_id,
         filename
       ) do
    Enum.reduce_while(base_sizes, [], fn {type, current_path, width, target_ext}, acc ->
      case prepare_variant(type, body, width, target_ext, current_path) do
        {:ok, processed_body, img_width, img_height} ->
          current_content_type =
            if target_ext in [".jpeg", ".jpg"], do: "image/jpeg", else: content_type

          variant = %{
            path: current_path,
            body: processed_body,
            content_type: current_content_type,
            original_hash:
              compute_hash(current_path, current_content_type, reference_type, reference_id),
            reference_type: reference_type,
            reference_id: reference_id,
            filename: filename,
            byte_size: byte_size(processed_body),
            width: img_width,
            height: img_height,
            variant: Atom.to_string(type),
            content_hash: content_hash(processed_body)
          }

          {:cont, [variant | acc]}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      variants -> {:ok, Enum.reverse(variants)}
    end
  end

  defp prepare_variant(:original, body, _width, _target_ext, _path) do
    case image_dimensions(body) do
      {:ok, width, height} -> {:ok, body, width, height}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_variant(type, body, width, target_ext, path) do
    process_image(body, width, target_ext, path, type)
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

  defp content_hash(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  defp create_asset_record(attrs) do
    path = attrs.path

    %{
      name: path,
      url: build_asset_url(path),
      url_suffix: build_url_suffix(path),
      content_type: attrs.content_type,
      reference_type: attrs.reference_type,
      reference_id: attrs.reference_id,
      original_hash: attrs.original_hash,
      filename: attrs.filename,
      byte_size: attrs.byte_size,
      width: attrs.width,
      height: attrs.height,
      variant: attrs.variant,
      content_hash: attrs.content_hash
    }
    |> create_asset()
  end

  defp create_asset_record!(attrs) do
    case create_asset_record(attrs) do
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

  # Resize image and return {body, width, height}
  defp process_image(body, width, target_ext, path, variant) do
    :telemetry.span(
      [:echo, :storage, :image, :process],
      %{
        path: path,
        variant: variant,
        width: width,
        target_ext: target_ext,
        file_size_bytes: byte_size(body)
      },
      fn ->
        result =
          with {:ok, thumbnail} <- Operation.thumbnail_buffer(body, width),
               {:ok, buffer} <- Image.write_to_buffer(thumbnail, target_ext) do
            {:ok, buffer, Image.width(thumbnail), Image.height(thumbnail)}
          else
            {:error, reason} -> {:error, reason}
          end

        metadata =
          case result do
            {:error, reason} ->
              %{
                path: path,
                variant: variant,
                width: width,
                target_ext: target_ext,
                file_size_bytes: byte_size(body),
                result: :error,
                error: inspect(reason)
              }

            {:ok, buffer, out_width, out_height} ->
              %{
                path: path,
                variant: variant,
                width: out_width,
                height: out_height,
                target_ext: target_ext,
                file_size_bytes: byte_size(buffer),
                result: :ok
              }
          end

        {result, metadata}
      end
    )
  end

  defp image_dimensions(body) do
    case Image.new_from_buffer(body) do
      {:ok, image} -> {:ok, Image.width(image), Image.height(image)}
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
end
