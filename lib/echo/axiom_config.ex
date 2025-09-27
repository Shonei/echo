defmodule Echo.AxiomConfig do
  @moduledoc """
  Configuration helper for Axiom logging integration.

  This module provides functions to validate and retrieve Axiom configuration
  from environment variables and application config.
  """

  @doc """
  Gets the Axiom API token from environment variables or application config.

  Looks for AXIOM_TOKEN environment variable first, then falls back to
  application config.
  """
  def get_token do
    System.get_env("AXIOM_TOKEN") ||
      Application.get_env(:echo, :axiom_token) ||
      raise_missing_config("AXIOM_TOKEN environment variable or :axiom_token config")
  end

  @doc """
  Gets the Axiom dataset name from environment variables or application config.

  Looks for AXIOM_DATASET environment variable first, then falls back to
  application config.
  """
  def get_dataset do
    System.get_env("AXIOM_DATASET") ||
      Application.get_env(:echo, :axiom_dataset) ||
      raise_missing_config("AXIOM_DATASET environment variable or :axiom_dataset config")
  end

  @doc """
  Gets the Axiom API URL from environment variables or application config.

  Defaults to US region (api.axiom.co) if not specified.
  For EU region, set to "https://api.eu.axiom.co"
  """
  def get_url do
    System.get_env("AXIOM_URL") ||
      Application.get_env(:echo, :axiom_url) ||
      "https://api.axiom.co"
  end

  @doc """
  Gets the batch size for log entries before flushing to Axiom.

  Defaults to 100 entries.
  """
  def get_batch_size do
    case System.get_env("AXIOM_BATCH_SIZE") do
      nil ->
        Application.get_env(:echo, :axiom_batch_size, 100)

      value ->
        String.to_integer(value)
    end
  end

  @doc """
  Gets the flush interval in milliseconds for sending logs to Axiom.

  Defaults to 5000ms (5 seconds).
  """
  def get_flush_interval do
    case System.get_env("AXIOM_FLUSH_INTERVAL") do
      nil ->
        Application.get_env(:echo, :axiom_flush_interval, 5_000)

      value ->
        String.to_integer(value)
    end
  end

  @doc """
  Validates that all required Axiom configuration is present.

  Returns :ok if valid, raises an error if any required config is missing.
  """
  def validate_config! do
    get_token()
    get_dataset()
    :ok
  end

  @doc """
  Returns a complete configuration map for the Axiom logger.
  """
  def logger_config do
    [
      axiom_token: get_token(),
      axiom_dataset: get_dataset(),
      axiom_url: get_url(),
      batch_size: get_batch_size(),
      flush_interval: get_flush_interval(),
      level: get_log_level()
    ]
  end

  @doc """
  Gets the minimum log level for Axiom logging.

  Defaults to :info level.
  """
  def get_log_level do
    case System.get_env("AXIOM_LOG_LEVEL") do
      nil ->
        Application.get_env(:echo, :axiom_log_level, :info)

      level_string ->
        String.to_existing_atom(level_string)
    end
  end

  @doc """
  Checks if Axiom logging is enabled.

  Returns true if AXIOM_ENABLED is set to "true" or if axiom_enabled config is true.
  Defaults to false for safety.
  """
  def enabled? do
    case System.get_env("AXIOM_ENABLED") do
      "true" -> true
      "false" -> false
      nil -> Application.get_env(:echo, :axiom_enabled, true)
      _ -> false
    end
  end

  defp raise_missing_config(config_name) do
    raise ArgumentError, """
    Missing required Axiom configuration: #{config_name}

    To configure Axiom logging, you need to set:
    - AXIOM_TOKEN environment variable (your Axiom API token)
    - AXIOM_DATASET environment variable (your Axiom dataset name)

    Optional configuration:
    - AXIOM_URL (defaults to https://api.axiom.co, use https://api.eu.axiom.co for EU)
    - AXIOM_BATCH_SIZE (defaults to 100)
    - AXIOM_FLUSH_INTERVAL (defaults to 5000ms)
    - AXIOM_LOG_LEVEL (defaults to info)
    - AXIOM_ENABLED (set to "true" to enable, defaults to false)

    Alternatively, you can set these in your application config:

    config :echo,
      axiom_token: "your-token",
      axiom_dataset: "your-dataset",
      axiom_enabled: true
    """
  end
end
