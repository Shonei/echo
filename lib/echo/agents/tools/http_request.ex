defmodule Echo.Agents.Tools.HttpRequest do
  @moduledoc """
  A generic HTTP tool the model can call, executed here on the server.

  The model picks the URL, so this is an SSRF risk by construction: every request
  is checked against `validate_url/1` first, which rejects non-HTTP schemes and
  any host that resolves to a loopback, private, link-local, or otherwise
  internal address — including the cloud metadata endpoint. Responses are capped
  so a large download cannot blow up the conversation or the context window.

  Only reachable when the operator ticks the tool on for a specific agent.
  """

  require Logger

  @max_body_bytes 512 * 1024
  @receive_timeout 15_000
  @pool_timeout 5_000
  @allowed_methods ~w(GET POST PUT PATCH DELETE HEAD)
  @max_headers 20

  # Hop-by-hop and identity headers the model has no business setting.
  @blocked_headers ~w(host content-length connection transfer-encoding upgrade
                      proxy-authorization proxy-authenticate te trailer)

  @doc """
  Canonical function declaration for this tool.

  Standard, lowercase-typed JSON Schema — each provider rewrites it into its
  own dialect via `Echo.Agents.Provider.build_function_tools/1` (Gemini wants
  the types upper-cased, OpenRouter takes them as they are).
  """
  def declaration do
    %{
      "name" => "http_request",
      "description" =>
        "Makes an HTTP request to a public URL and returns the status, headers, and body. " <>
          "Use it to call public APIs or fetch a page's raw content. Requests to private, " <>
          "internal, or loopback addresses are refused. Large bodies are truncated.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The absolute http:// or https:// URL to request."
          },
          "method" => %{
            "type" => "string",
            "description" => "HTTP method. Defaults to GET.",
            "enum" => @allowed_methods
          },
          "headers" => %{
            "type" => "object",
            "description" =>
              "Optional request headers as a flat object of string values, e.g. {\"Accept\": \"application/json\"}."
          },
          "body" => %{
            "type" => "string",
            "description" =>
              "Optional request body, already serialised. Set a matching Content-Type header."
          }
        },
        "required" => ["url"]
      }
    }
  end

  @doc """
  Runs a call from the model. Always returns a map to hand back as the
  `functionResponse`, including for failures — the model should see the error
  and be able to react to it rather than the turn blowing up.
  """
  def run(args) when is_map(args) do
    url = args["url"]
    method = normalize_method(args["method"])

    with {:ok, method} <- method,
         {:ok, url} <- validate_url(url) do
      request(method, url, args["headers"], args["body"])
    else
      {:error, reason} -> %{"error" => reason}
    end
  end

  def run(_), do: %{"error" => "Invalid arguments: expected an object with a url."}

  @doc """
  Checks a model-supplied URL. Returns `{:ok, url}` or `{:error, reason}`.
  """
  def validate_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, "Only http and https URLs are allowed."}

      %URI{host: host} when is_nil(host) or host == "" ->
        {:error, "URL is missing a host."}

      %URI{host: host} = uri ->
        case resolve(host) do
          {:ok, addresses} ->
            if Enum.any?(addresses, &internal_address?/1) do
              {:error, "Refusing to request #{host}: it resolves to an internal address."}
            else
              {:ok, URI.to_string(uri)}
            end

          {:error, reason} ->
            {:error, "Could not resolve #{host}: #{reason}."}
        end
    end
  end

  def validate_url(_), do: {:error, "A url is required."}

  # --- Internals ---

  defp request(method, url, headers, body) do
    headers = build_headers(headers)
    body = if method in ["GET", "HEAD"], do: nil, else: body
    started_at = System.monotonic_time(:millisecond)

    req = Finch.build(method_atom(method), url, headers, body)

    case Finch.request(req, Echo.Finch,
           receive_timeout: @receive_timeout,
           pool_timeout: @pool_timeout
         ) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at
        {body, truncated?} = truncate(resp_body)

        Logger.info("http_request tool completed",
          method: method,
          url: redact(url),
          status: status,
          duration_ms: duration_ms,
          response_bytes: byte_size(resp_body),
          truncated: truncated?
        )

        %{
          "status" => status,
          "headers" => Map.new(resp_headers),
          "body" => body,
          "truncated" => truncated?
        }

      {:error, exception} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        Logger.warning("http_request tool failed",
          method: method,
          url: redact(url),
          duration_ms: duration_ms,
          error: inspect(exception)
        )

        %{"error" => "Request failed: #{Exception.message(exception)}"}
    end
  end

  # A skill can substitute a variable into a URL, and plenty of APIs want the
  # credential in the query string. `Echo.Agents.Variables` keeps that value out
  # of the transcript, but the log is a different sink entirely -- so drop the
  # query and any userinfo before writing the URL to it. The host and path are
  # what makes a log line useful; neither is the secret.
  @doc false
  def redact(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{} = uri -> URI.to_string(%{uri | query: nil, userinfo: nil})
    end
  rescue
    _ -> "[unparseable url]"
  end

  def redact(url), do: inspect(url)

  defp truncate(body) when is_binary(body) do
    if byte_size(body) > @max_body_bytes do
      {binary_part(body, 0, @max_body_bytes), true}
    else
      {body, false}
    end
  end

  defp truncate(_), do: {"", false}

  defp build_headers(headers) when is_map(headers) do
    headers
    |> Enum.filter(fn {key, value} -> is_binary(key) and is_binary(value) end)
    |> Enum.reject(fn {key, _} -> String.downcase(key) in @blocked_headers end)
    |> Enum.take(@max_headers)
  end

  defp build_headers(_), do: []

  defp normalize_method(nil), do: {:ok, "GET"}

  defp normalize_method(method) when is_binary(method) do
    upcased = method |> String.trim() |> String.upcase()

    if upcased in @allowed_methods do
      {:ok, upcased}
    else
      {:error,
       "Method #{upcased} is not allowed. Use one of: #{Enum.join(@allowed_methods, ", ")}."}
    end
  end

  defp normalize_method(_), do: {:error, "Invalid method."}

  defp method_atom(method), do: method |> String.downcase() |> String.to_existing_atom()

  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        v4 = :inet.getaddrs(charlist, :inet)
        v6 = :inet.getaddrs(charlist, :inet6)

        case {v4, v6} do
          {{:ok, a}, {:ok, b}} -> {:ok, a ++ b}
          {{:ok, a}, _} -> {:ok, a}
          {_, {:ok, b}} -> {:ok, b}
          {{:error, reason}, _} -> {:error, to_string(:inet.format_error(reason))}
        end
    end
  end

  # IPv4
  defp internal_address?({127, _, _, _}), do: true
  defp internal_address?({10, _, _, _}), do: true
  defp internal_address?({192, 168, _, _}), do: true
  defp internal_address?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  # Link-local, which covers the 169.254.169.254 cloud metadata endpoint.
  defp internal_address?({169, 254, _, _}), do: true
  defp internal_address?({0, _, _, _}), do: true
  # Carrier-grade NAT, IETF protocol assignments, benchmarking, multicast, reserved.
  defp internal_address?({100, second, _, _}) when second >= 64 and second <= 127, do: true
  defp internal_address?({192, 0, 0, _}), do: true
  defp internal_address?({198, 18, _, _}), do: true
  defp internal_address?({198, 19, _, _}), do: true
  defp internal_address?({first, _, _, _}) when first >= 224, do: true

  # IPv6
  defp internal_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp internal_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv4-mapped (::ffff:a.b.c.d) — check the embedded v4 address.
  defp internal_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    internal_address?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  # Unique local fc00::/7 and link-local fe80::/10.
  defp internal_address?({first, _, _, _, _, _, _, _})
       when (first >= 0xFC00 and first <= 0xFDFF) or (first >= 0xFE80 and first <= 0xFEBF),
       do: true

  defp internal_address?(_), do: false
end
