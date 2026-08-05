defmodule EchoWeb.Telemetry do
  use Supervisor
  require Logger
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    :ok =
      :telemetry.attach(
        "echo-handler",
        [:echo, :repo, :query],
        &handle_event/4,
        %{}
      )

    :ok =
      :telemetry.attach(
        "echo-router-handler_custom",
        [:phoenix, :endpoint, :stop],
        &log_http_request/4,
        %{}
      )

    :ok =
      :telemetry.attach_many(
        "echo-storage-instrumentation",
        [
          [:echo, :storage, :asset, :upload, :stop],
          [:echo, :storage, :image, :process, :stop],
          [:echo, :storage, :s3, :download, :stop],
          [:echo, :storage, :s3, :upload, :stop]
        ],
        &log_storage_event/4,
        %{}
      )

    :ok =
      :telemetry.attach_many(
        "echo-storage-exceptions",
        [
          [:echo, :storage, :asset, :upload, :exception],
          [:echo, :storage, :image, :process, :exception],
          [:echo, :storage, :s3, :download, :exception],
          [:echo, :storage, :s3, :upload, :exception]
        ],
        &log_storage_exception/4,
        %{}
      )

    Supervisor.init(children, strategy: :one_for_one)
  end

  def log_storage_event(event_name, measurements, metadata, _config) do
    action = event_name |> Enum.drop(-1) |> Enum.join(".")
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    result = metadata[:result] || :ok
    level = if result == :error, do: :error, else: :info

    Logger.log(
      level,
      storage_message(action, result),
      [
        action: action,
        duration_ms: duration_ms,
        result: result,
        path: metadata[:path],
        variant: metadata[:variant],
        width: metadata[:width],
        target_ext: metadata[:target_ext],
        content_type: metadata[:content_type],
        file_size_bytes: metadata[:file_size_bytes],
        variant_count: metadata[:variant_count],
        image?: metadata[:image?],
        error: metadata[:error]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    )
  end

  def log_storage_exception(event_name, measurements, metadata, _config) do
    action = event_name |> Enum.drop(-1) |> Enum.join(".")
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    kind = metadata[:kind]
    reason = metadata[:reason]

    Logger.error("Storage operation crashed",
      action: action,
      duration_ms: duration_ms,
      path: metadata[:path],
      kind: kind,
      error: Exception.format(kind, reason, metadata[:stacktrace] || [])
    )
  end

  def log_http_request(_event, measurements, metadata, _config) do
    conn = metadata.conn

    duration_ms =
      System.convert_time_unit(Map.get(measurements, :duration), :native, :millisecond)

    status = conn.status
    level = if is_integer(status) and status >= 500, do: :error, else: :info

    Logger.log(
      level,
      "HTTP Request",
      [
        duration_ms: duration_ms,
        method: conn.method,
        path: conn.request_path,
        query_string: blank_to_nil(conn.query_string),
        status: status,
        remote_ip: format_ip(conn),
        req_content_length: req_content_length(conn),
        user_agent: req_header(conn, "user-agent")
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    )
  end

  def handle_event([:echo, :repo, :query], measurements, metadata, _config) do
    total_time = measurements.total_time
    ms_total_time = System.convert_time_unit(total_time, :native, :millisecond)

    if ms_total_time > 1_000 do
      query = metadata.query

      Logger.info("SLOW QUERY", query: query, times: measurements)
    end
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("echo.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("echo.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("echo.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("echo.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("echo.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Storage Metrics
      summary("echo.storage.asset.upload.stop.duration",
        unit: {:native, :millisecond},
        description: "End-to-end time spent uploading an asset (including image variants)"
      ),
      summary("echo.storage.s3.upload.stop.duration",
        unit: {:native, :millisecond},
        description: "Time spent uploading objects to S3"
      ),
      summary("echo.storage.s3.download.stop.duration",
        unit: {:native, :millisecond},
        description: "Time spent downloading objects from S3"
      ),
      summary("echo.storage.image.process.stop.duration",
        unit: {:native, :millisecond},
        description: "Time spent processing/resizing images"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp storage_message("echo.storage.asset.upload", :ok), do: "Asset upload completed"
  defp storage_message("echo.storage.asset.upload", :error), do: "Asset upload failed"
  defp storage_message("echo.storage.image.process", :ok), do: "Image processing completed"
  defp storage_message("echo.storage.image.process", :error), do: "Image processing failed"
  defp storage_message("echo.storage.s3.download", :ok), do: "S3 download completed"
  defp storage_message("echo.storage.s3.download", :error), do: "S3 download failed"
  defp storage_message("echo.storage.s3.upload", :ok), do: "S3 upload completed"
  defp storage_message("echo.storage.s3.upload", :error), do: "S3 upload failed"
  defp storage_message(action, :ok), do: "Storage operation completed (#{action})"
  defp storage_message(action, :error), do: "Storage operation failed (#{action})"

  defp format_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp req_content_length(conn) do
    case req_header(conn, "content-length") do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp req_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {EchoWeb, :count_users, []}
    ]
  end
end

# Saved my life here https://stratus3d.com/blog/2023/10/15/show-all-telemetry-events-in-erlang-and-elixir/?utm_source=elixir-merge
defmodule TelemetryHelper do
  @moduledoc """
  Helper functions for seeing all telemetry events.
  Only for use in development.
  """

  @doc """
  attach_all/0 prints out all telemetry events received by default.
  Optionally, you can specify a handler function that will be invoked
  with the same three arguments that the `:telemetry.execute/3` and
  `:telemetry.span/3` functions were invoked with.
  """
  def attach_all(function \\ &default_handler_fn/3) do
    # Start the tracer
    :dbg.start()

    # Create tracer process with a function that pattern matches out the three arguments the telemetry calls are made with.
    :dbg.tracer(
      :process,
      {fn
         {_, _, _, {_mod, :execute, [name, measurement, metadata]}}, _state ->
           function.(name, metadata, measurement)

         {_, _, _, {_mod, :span, [name, metadata, span_fun]}}, _state ->
           function.(name, metadata, span_fun)
       end, nil}
    )

    # Trace all processes
    :dbg.p(:all, :c)

    # Trace calls to the functions used to emit telemetry events
    :dbg.tp(:telemetry, :execute, 3, [])
    :dbg.tp(:telemetry, :span, 3, [])
  end

  def stop do
    # Stop tracer
    :dbg.stop()
  end

  defp default_handler_fn(name, metadata, measure_or_fun) do
    # Print out telemetry info
    IO.puts(
      "Telemetry event:#{inspect(name)}\nwith #{inspect(measure_or_fun)} and #{inspect(metadata)}"
    )
  end
end
