defmodule Echo.FakeHTTPClient do
  @moduledoc """
  A stand-in for `Finch` in provider tests.

  The providers call their HTTP client through a configured module
  (`config :echo, Echo.Agents.Providers.Gemini, http_client: ...`), so pointing
  that at this module is the whole test seam — no mocking library and no local
  server involved.

  Stubs and recorded requests live in the application environment rather than
  the process dictionary, because the process that sets a stub (the test) is
  not the one that makes the call (a `Echo.Agents.ConversationServer`). That
  makes the state global, so **tests using this must be `async: false`** and
  should `reset/0` in setup.
  """

  @stub_key :fake_http_client_stubs
  @requests_key :fake_http_client_requests

  @doc """
  Clears stubs and recorded requests. Call in `setup`.
  """
  def reset do
    Application.delete_env(:echo, @stub_key)
    Application.delete_env(:echo, @requests_key)
    :ok
  end

  @doc """
  Sets one response, returned for every request until changed.

  Takes `{:ok, %{status: status, body: body}}` or `{:error, exception}` — the
  shapes `Finch.request/3` produces. A bare map is treated as a JSON body to be
  encoded and returned with status 200.
  """
  def stub(response), do: stub_sequence([response])

  @doc """
  Queues responses, one per request, in order.

  Use for a tool round-trip, where one `message/2` makes several calls. The
  last response repeats once the queue runs dry.
  """
  def stub_sequence(responses) when is_list(responses) do
    Application.put_env(:echo, @stub_key, Enum.map(responses, &normalize/1))
    :ok
  end

  @doc """
  Every request made since `reset/0`, oldest first, as
  `%{method:, url:, headers:, body:}` with `body` already JSON-decoded.
  """
  def requests, do: Application.get_env(:echo, @requests_key, [])

  @doc """
  The most recent request, or `nil` if nothing was sent.
  """
  def last_request, do: requests() |> List.last()

  # --- Finch-shaped API ---

  def build(method, url, headers \\ [], body \\ nil) do
    %{method: method, url: url, headers: headers, body: decode(body)}
  end

  def request(request, _name, _opts \\ []) do
    Application.put_env(:echo, @requests_key, requests() ++ [request])

    case Application.get_env(:echo, @stub_key, []) do
      [] ->
        {:ok, %{status: 200, body: "{}"}}

      # The last stub repeats rather than running out, so a test only has to
      # queue the responses it actually cares about.
      [only] ->
        only

      [next | rest] ->
        Application.put_env(:echo, @stub_key, rest)
        next
    end
  end

  defp normalize({:ok, _} = response), do: response
  defp normalize({:error, _} = response), do: response

  defp normalize(json_body) when is_map(json_body),
    do: {:ok, %{status: 200, body: Jason.encode!(json_body)}}

  defp decode(nil), do: nil

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end
