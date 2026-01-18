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

  use GenServer
  require Logger

  defstruct [:endpoint, :region, :bucket, :access_key_id, :secret_access_key, :http_client]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets an object from storage.

  Returns `{:ok, body, content_type}` on success or `{:error, reason}` on failure.

  ## Example

      {:ok, body, "image/png"} = S3Client.get_object("images/photo.png")
  """
  def get_object(path) do
    GenServer.call(__MODULE__, {:get_object, path})
  end

  @doc """
  Uploads an object to storage.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Example

      :ok = S3Client.upload_object("images/photo.png", binary_data, "image/png")
  """
  def upload_object(path, body, content_type \\ "application/octet-stream") do
    GenServer.call(__MODULE__, {:upload_object, path, body, content_type}, 60_000)
  end

  @doc """
  Lists objects in storage with an optional prefix.

  Returns `{:ok, [%{key: key, size: size, last_modified: datetime}]}` on success.

  ## Example

      {:ok, objects} = S3Client.list_objects("images/")
  """
  def list_objects(prefix \\ "") do
    GenServer.call(__MODULE__, {:list_objects, prefix})
  end

  @doc """
  Deletes an object from storage.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Example

      :ok = S3Client.delete_object("images/photo.png")
  """
  def delete_object(path) do
    GenServer.call(__MODULE__, {:delete_object, path})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    config = Application.get_env(:echo, __MODULE__, [])

    state = %__MODULE__{
      endpoint: Keyword.fetch!(config, :endpoint),
      region: Keyword.get(config, :region, "auto"),
      bucket: Keyword.fetch!(config, :bucket),
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: fetch_secret_access_key(config),
      http_client: Keyword.get(config, :http_client, HTTPoison)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_object, path}, _from, state) do
    result = do_get_object(state, path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:upload_object, path, body, content_type}, _from, state) do
    result = do_upload_object(state, path, body, content_type)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_objects, prefix}, _from, state) do
    result = do_list_objects(state, prefix)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_object, path}, _from, state) do
    result = do_delete_object(state, path)
    {:reply, result, state}
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

    case state.http_client.get(url, headers, timeout: 30_000, recv_timeout: 30_000) do
      {:ok, %{status_code: 200, body: body, headers: resp_headers}} ->
        content_type = get_header(resp_headers, "content-type", "application/octet-stream")
        {:ok, body, content_type}

      {:ok, %{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %{status_code: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
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

    Logging.info("Uploading object to S3", %{url: url, headers: headers})

    case state.http_client.put(url, body, headers, timeout: 60_000, recv_timeout: 60_000) do
      {:ok, %{status_code: status}} when status in 200..299 ->
        :ok

      {:ok, %{status_code: status, body: resp_body}} ->
        {:error, "HTTP #{status}: #{resp_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_list_objects(state, prefix) do
    query = if prefix != "", do: "?list-type=2&prefix=#{URI.encode(prefix)}", else: "?list-type=2"
    url = build_url(state, "") <> query
    headers = sign_request(state, "GET", "", "", [], query)

    case state.http_client.get(url, headers, timeout: 30_000, recv_timeout: 30_000) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, parse_list_objects_response(body)}

      {:ok, %{status_code: status, body: resp_body}} ->
        {:error, "HTTP #{status}: #{resp_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_delete_object(state, path) do
    url = build_url(state, path)
    headers = sign_request(state, "DELETE", path, "", [])

    case state.http_client.delete(url, headers, timeout: 30_000, recv_timeout: 30_000) do
      {:ok, %{status_code: status}} when status in [200, 204] ->
        :ok

      {:ok, %{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %{status_code: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
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
