defmodule Echo.AxiomLogger do
  @moduledoc """
  A GenServer-based logger backend that sends logs to Axiom.

  This backend batches log entries and sends them to Axiom's ingest API
  in configurable intervals to optimize performance.
  """

  use GenServer

  defstruct [
    :name,
    :level,
    :axiom_token,
    :axiom_dataset,
    :axiom_url,
    :batch_size,
    :flush_interval,
    :buffer,
    :timer_ref,
    :http_client
  ]

  @default_batch_size 100
  # 5 seconds
  @default_flush_interval 5_000
  @default_axiom_url "https://api.axiom.co"
  # Capture Mix.env at compile time since Mix is not available in releases
  @compile_env Mix.env() |> to_string()

  ## GenServer API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def log(level, message, metadata) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:log, level, message, metadata})
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(config) do
    state = %__MODULE__{
      name: :axiom_logger,
      level: get_config(config, :level, :info),
      axiom_token: get_required_config(config, :axiom_token),
      axiom_dataset: get_required_config(config, :axiom_dataset),
      axiom_url: get_config(config, :axiom_url, @default_axiom_url),
      batch_size: get_config(config, :batch_size, @default_batch_size),
      flush_interval: get_config(config, :flush_interval, @default_flush_interval),
      buffer: [],
      timer_ref: nil,
      http_client: get_config(config, :http_client, HTTPoison)
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_cast({:log, level, message, metadata}, state) do
    if meet_level?(level, state.level) do
      try do
        timestamp = System.system_time(:microsecond)
        log_entry = format_log_entry(level, message, timestamp, metadata)
        new_state = add_to_buffer(log_entry, state)

        if length(new_state.buffer) >= state.batch_size do
          {:noreply, flush_buffer(new_state)}
        else
          {:noreply, new_state}
        end
      rescue
        error ->
          # Use IO.puts to avoid recursive logging
          IO.puts(
            "AxiomLogger: Failed to format log entry: #{inspect(error)}, message: #{inspect(message)}"
          )

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush_timer, state) do
    new_state = flush_buffer(state)
    {:noreply, schedule_flush(new_state)}
  end

  @impl true
  def terminate(_reason, state) do
    flush_buffer(state)
    :ok
  end

  ## Private functions

  defp get_required_config(config, key) do
    case get_config(config, key) do
      nil ->
        raise ArgumentError, "#{key} is required for AxiomLogger"

      value ->
        value
    end
  end

  defp get_config(config, key, default \\ nil)

  defp get_config(config, key, default) when is_map(config) do
    Map.get(config, key, default)
  end

  defp get_config(config, key, default) when is_list(config) do
    Keyword.get(config, key, default)
  end

  defp meet_level?(lvl, min) do
    Logger.compare_levels(lvl, min) != :lt
  end

  defp format_log_entry(level, msg, timestamp, metadata) do
    %{
      timestamp: format_timestamp(timestamp),
      level: to_string(level),
      message: format_message(msg),
      metadata: format_metadata(metadata),
      # Add some standard fields that are useful in Axiom
      service: "echo",
      environment: get_environment(),
      node: to_string(node())
    }
  end

  defp format_message(msg) when is_binary(msg), do: msg
  defp format_message({:string, iodata}), do: IO.iodata_to_binary(iodata)
  defp format_message({:report, report}) when is_map(report), do: inspect(report)
  defp format_message({:report, report}), do: inspect(report)
  defp format_message(msg) when is_list(msg), do: IO.iodata_to_binary(msg)
  defp format_message(msg), do: inspect(msg)

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    # Convert microsecond timestamp to ISO8601
    timestamp
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp format_timestamp({{year, month, day}, {hour, minute, second, microsecond}}) do
    # Format as ISO8601 timestamp that Axiom expects
    "#{year}-#{pad(month)}-#{pad(day)}T#{pad(hour)}:#{pad(minute)}:#{pad(second)}.#{pad_microsecond(microsecond)}Z"
  end

  defp pad(int) when int < 10, do: "0#{int}"
  defp pad(int), do: "#{int}"

  defp pad_microsecond(microsecond) do
    microsecond
    |> div(1000)
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
  end

  defp format_metadata(metadata) when is_list(metadata) do
    # First sanitize values in the keyword list before converting to map
    # This handles cases where values are structs like Plug.Conn
    metadata
    |> Enum.map(fn {key, value} -> {key, sanitize_value(value)} end)
    |> Enum.into(%{})
    # Remove internal fields
    |> Map.drop([:pid, :gl, :time, :file])
  end

  defp format_metadata(%{__struct__: _} = metadata) do
    # Handle structs by inspecting them
    %{struct: inspect(metadata)}
  end

  defp format_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([:pid, :gl, :time, :file])
    |> sanitize_metadata()
  end

  defp format_metadata(_), do: %{}

  # Sanitize metadata to ensure all values are JSON-serializable
  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {key, sanitize_value(value)} end)
    |> Enum.into(%{})
  end

  # Convert MFA tuples to strings
  defp sanitize_value({module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    "#{module}.#{function}/#{arity}"
  end

  # Convert other tuples to strings
  defp sanitize_value(value) when is_tuple(value) do
    inspect(value)
  end

  # Convert PIDs to strings
  defp sanitize_value(value) when is_pid(value) do
    inspect(value)
  end

  # Convert references to strings
  defp sanitize_value(value) when is_reference(value) do
    inspect(value)
  end

  # Convert functions to strings
  defp sanitize_value(value) when is_function(value) do
    inspect(value)
  end

  # Handle structs (like Plug.Conn) by inspecting them
  defp sanitize_value(%{__struct__: _} = value) do
    inspect(value)
  end

  # Handle nested maps
  defp sanitize_value(value) when is_map(value) do
    sanitize_metadata(value)
  end

  # Handle lists
  defp sanitize_value(value) when is_list(value) do
    Enum.map(value, &sanitize_value/1)
  end

  # Keep JSON-serializable values as-is
  defp sanitize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    value
  end

  # Convert atoms to strings
  defp sanitize_value(value) when is_atom(value) do
    to_string(value)
  end

  # Fallback: convert anything else to string
  defp sanitize_value(value) do
    inspect(value)
  end

  defp get_environment do
    Application.get_env(:echo, :environment, @compile_env)
  end

  defp add_to_buffer(log_entry, state) do
    %{state | buffer: [log_entry | state.buffer]}
  end

  defp flush_buffer(%{buffer: []} = state), do: state

  defp flush_buffer(state) do
    # Reverse buffer to maintain chronological order
    logs = Enum.reverse(state.buffer)

    # Send logs in a separate task to avoid blocking the GenServer
    Task.start(fn ->
      case send_to_axiom(logs, state) do
        :ok ->
          # Use IO.puts to avoid recursive logging
          if Application.get_env(:echo, :debug_axiom_logger, false) do
            IO.puts("AxiomLogger: Successfully sent #{length(logs)} logs to Axiom")
          end

        {:error, reason} ->
          # Use IO.puts to avoid recursive logging
          IO.puts("AxiomLogger: Failed to send logs to Axiom: #{inspect(reason)}")
      end
    end)

    %{state | buffer: []}
  end

  defp send_to_axiom(logs, state) do
    url = "#{state.axiom_url}/v1/datasets/#{state.axiom_dataset}/ingest"

    headers = [
      {"Authorization", "Bearer #{state.axiom_token}"},
      {"Content-Type", "application/json"}
    ]

    # IO.inspect(url)
    # IO.inspect(headers)

    body = Jason.encode!(logs)

    case state.http_client.post(url, body, headers, timeout: 30_000) do
      {:ok, %{status_code: status}} when status in 200..299 ->
        :ok

      {:ok, %{status_code: status, body: response_body}} ->
        {:error, "HTTP #{status}: #{response_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      {:error, exception}
  end

  defp schedule_flush(state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    timer_ref = Process.send_after(self(), :flush_timer, state.flush_interval)
    %{state | timer_ref: timer_ref}
  end
end
