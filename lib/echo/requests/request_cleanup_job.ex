defmodule Echo.Requests.RequestCleanupJob do
  @moduledoc """
  A GenServer that periodically cleans up old HTTP requests from the database.

  This job:
  - Runs once immediately when the application starts
  - Runs every hour to delete requests older than 2 days
  """

  use GenServer
  require Logger

  # 1 hour in milliseconds
  @cleanup_interval_ms :timer.hours(1)
  # Requests older than 2 days will be deleted
  @max_age_days 2

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Run cleanup immediately on startup
    send(self(), :cleanup)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    run_cleanup()

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, state}
  end

  ## Private Functions

  defp run_cleanup do
    Logger.info("Starting cleanup of old HTTP requests (older than #{@max_age_days} days)")

    case Echo.Requests.delete_requests_older_than_days(@max_age_days) do
      {count, _} when count > 0 ->
        Logger.info("Deleted #{count} old HTTP requests")

      {0, _} ->
        Logger.debug("No old HTTP requests to delete")
    end
  rescue
    error ->
      Logger.error("Failed to cleanup old requests: #{inspect(error)}")
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end

