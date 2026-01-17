defmodule EchoWeb.Plugs.RateLimit do
  @moduledoc """
  A simple rate limiting plug using ETS for tracking requests.

  ## Usage

      plug EchoWeb.Plugs.RateLimit, interval_ms: 5000

  This will limit requests to 1 per 5 seconds per IP address.
  """

  import Plug.Conn

  @table_name :rate_limit_requests

  def init(opts) do
    # Ensure ETS table exists
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:set, :public, :named_table])
    end

    interval_ms = Keyword.get(opts, :interval_ms, 5000)
    %{interval_ms: interval_ms}
  end

  def call(conn, %{interval_ms: interval_ms}) do
    key = rate_limit_key(conn)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, key) do
      [{^key, last_request_time}] ->
        if now - last_request_time < interval_ms do
          retry_after_seconds = div(interval_ms - (now - last_request_time), 1000) + 1

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
          |> send_resp(429, Jason.encode!(%{error: "Too many requests. Please wait before uploading again."}))
          |> halt()
        else
          :ets.insert(@table_name, {key, now})
          conn
        end

      [] ->
        :ets.insert(@table_name, {key, now})
        conn
    end
  end

  defp rate_limit_key(conn) do
    ip =
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] ->
          forwarded
          |> String.split(",")
          |> List.first()
          |> String.trim()

        [] ->
          conn.remote_ip
          |> :inet.ntoa()
          |> to_string()
      end

    {:upload_rate_limit, ip}
  end
end

