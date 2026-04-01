defmodule Echo.Storage.S3Client do
  @moduledoc """
  A simple S3-compatible storage client GenServer for managing assets like images and files.

  Supports:
  - Get object
  - Upload object
  - List objects
  - Delete object

  Works with any S3-compatible storage (AWS S3, Railway, MinIO, etc.)
  using AWS Signature V4 for authentication.

  ## Configuration

      config :echo, Echo.Storage.S3Client,
        endpoint: "https://storage.railway.app",
        region: "auto",
        bucket: "my-bucket",
        access_key_id: "access-key"
        # secret_access_key loaded from S3_SECRET_ACCESS_KEY env var
  """

  require Logger

  defstruct [:endpoint, :region, :bucket, :access_key_id, :secret_access_key, :finch_name]

  # Client API

  @doc """
  Gets an object from storage.

  Returns `{:ok, body, content_type}` on success or `{:error, reason}` on failure.

  ## Example

      {:ok, body, "image/png"} = S3Client.get_object("images/photo.png")
  """
  def get_object(path) do
    :telemetry.span(
      [:echo, :storage, :s3, :download],
      %{path: path},
      fn ->
        result = do_get_object(get_config(), path)

        metadata =
          case result do
            {:ok, body, _content_type} ->
              %{path: path, file_size_bytes: byte_size(body)}

            _error ->
              %{path: path}
          end

        {result, metadata}
      end
    )
  end

  @doc """
  Uploads an object to storage.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Example

      :ok = S3Client.upload_object("images/photo.png", binary_data, "image/png")
  """
  def upload_object(path, body, content_type \\ "application/octet-stream") do
    file_size = byte_size(body)

    :telemetry.span(
      [:echo, :storage, :s3, :upload],
      %{path: path, content_type: content_type, file_size_bytes: file_size},
      fn ->
        result = do_upload_object(get_config(), path, body, content_type)
        {result, %{path: path, file_size_bytes: file_size}}
      end
    )
  end

  @doc """
  Lists objects in storage with an optional prefix.

  Returns `{:ok, [%{key: key, size: size, last_modified: datetime}]}` on success.

  ## Example

      {:ok, objects} = S3Client.list_objects("images/")
  """
  def list_objects(prefix \\ "") do
    do_list_objects(get_config(), prefix)
  end

  @doc """
  Deletes an object from storage.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Example

      :ok = S3Client.delete_object("images/photo.png")
  """
  def delete_object(path) do
    do_delete_object(get_config(), path)
  end

  # Configuration

  defp get_config do
    config = Application.get_env(:echo, __MODULE__, [])

    %__MODULE__{
      endpoint: Keyword.fetch!(config, :endpoint),
      region: Keyword.get(config, :region, "auto"),
      bucket: Keyword.fetch!(config, :bucket),
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: fetch_secret_access_key(config),
      finch_name: Keyword.get(config, :finch_name, Echo.Finch)
    }
  end

  # Private functions

  defp fetch_secret_access_key(config) do
    System.get_env("S3_SECRET_ACCESS_KEY") ||
      Keyword.get(config, :secret_access_key) ||
      raise "S3_SECRET_ACCESS_KEY environment variable or :secret_access_key config is required"
  end

  defp do_get_object(state, path) do
    url = build_url(state, path)
    headers = sign_request(state, "GET", path, "", [])

    req = Finch.build(:get, url, headers)
    case Finch.request(req, state.finch_name, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body, headers: resp_headers}} ->
        content_type = get_header(resp_headers, "content-type", "application/octet-stream")
        {:ok, body, content_type}

      {:ok, %Finch.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp get_header(headers, name, default) do
    name_downcase = String.downcase(name)

    Enum.find_value(headers, default, fn {key, value} ->
      if String.downcase(key) == name_downcase, do: value
    end)
  end

  defp do_upload_object(state, path, body, content_type) do
    url = build_url(state, path)
    headers = sign_request(state, "PUT", path, body, [{"content-type", content_type}])

    req = Finch.build(:put, url, headers, body)
    case Finch.request(req, state.finch_name, receive_timeout: 60_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, "HTTP #{status}: #{resp_body}"}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp do_list_objects(state, prefix) do
    query = if prefix != "", do: "?list-type=2&prefix=#{URI.encode(prefix)}", else: "?list-type=2"
    url = build_url(state, "") <> query
    headers = sign_request(state, "GET", "", "", [], query)

    req = Finch.build(:get, url, headers)
    case Finch.request(req, state.finch_name, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, parse_list_objects_response(body)}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, "HTTP #{status}: #{resp_body}"}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp do_delete_object(state, path) do
    url = build_url(state, path)
    headers = sign_request(state, "DELETE", path, "", [])

    req = Finch.build(:delete, url, headers)
    case Finch.request(req, state.finch_name, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Finch.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # URL Building

  defp build_url(state, path) do
    endpoint = String.trim_trailing(state.endpoint, "/")
    bucket = state.bucket
    full_path = if path == "", do: "/#{bucket}", else: "/#{bucket}/#{URI.encode(path)}"
    "#{endpoint}#{full_path}"
  end

  defp get_host(state) do
    state.endpoint
    |> URI.parse()
    |> Map.get(:host)
  end

  # AWS Signature V4 Implementation

  defp sign_request(state, method, path, payload, extra_headers, query \\ "") do
    now = DateTime.utc_now()
    amz_date = format_amz_date(now)
    date_stamp = format_date_stamp(now)

    host = get_host(state)
    bucket = state.bucket
    payload_hash = hash_sha256(payload)

    headers =
      [
        {"host", host},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date}
      ] ++ extra_headers

    signed_headers = headers |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(";")

    canonical_path = if path == "", do: "/#{bucket}", else: "/#{bucket}/#{URI.encode(path)}"
    canonical_query = String.trim_leading(query, "?")

    canonical_headers =
      headers
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> "#{k}:#{String.trim(v)}\n" end)
      |> Enum.join()

    canonical_request =
      [method, canonical_path, canonical_query, canonical_headers, signed_headers, payload_hash]
      |> Enum.join("\n")

    credential_scope = "#{date_stamp}/#{state.region}/s3/aws4_request"

    string_to_sign =
      ["AWS4-HMAC-SHA256", amz_date, credential_scope, hash_sha256(canonical_request)]
      |> Enum.join("\n")

    signing_key = derive_signing_key(state.secret_access_key, date_stamp, state.region, "s3")
    signature = hmac_sha256_hex(signing_key, string_to_sign)

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{state.access_key_id}/#{credential_scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    [{"Authorization", authorization} | Enum.map(headers, fn {k, v} -> {k, v} end)]
  end

  defp derive_signing_key(secret_key, date_stamp, region, service) do
    ("AWS4" <> secret_key)
    |> hmac_sha256(date_stamp)
    |> hmac_sha256(region)
    |> hmac_sha256(service)
    |> hmac_sha256("aws4_request")
  end

  defp hash_sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hmac_sha256_hex(key, data), do: hmac_sha256(key, data) |> Base.encode16(case: :lower)

  defp format_amz_date(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp format_date_stamp(datetime) do
    datetime |> DateTime.to_date() |> Calendar.strftime("%Y%m%d")
  end

  defp parse_list_objects_response(xml_body) do
    # Simple XML parsing for S3 ListObjectsV2 response
    ~r/<Contents>.*?<Key>(?<key>.*?)<\/Key>.*?<LastModified>(?<last_modified>.*?)<\/LastModified>.*?<Size>(?<size>\d+)<\/Size>.*?<\/Contents>/s
    |> Regex.scan(xml_body, capture: :all_names)
    |> Enum.map(fn [key, last_modified, size] ->
      %{
        key: key,
        last_modified: last_modified,
        size: String.to_integer(size)
      }
    end)
  end
end
