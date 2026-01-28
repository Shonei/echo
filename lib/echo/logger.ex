defmodule Echo.Logger do
  require Logger

  # Capture Mix.env at compile time since Mix is not available in releases
  @compile_env Mix.env() |> to_string()

  def info(message, labels \\ %{}) do
    Logger.info(message, format_metadata(labels))
  end

  def error(message, labels \\ %{}) do
    Logger.error(message, format_metadata(labels))
  end

  def warn(message, labels \\ %{}) do
    Logger.warning(message, format_metadata(labels))
  end

  def debug(message, labels \\ %{}) do
    Logger.debug(message, format_metadata(labels))
  end

  # Convert map labels to keyword list for better Logger integration
  defp format_metadata(labels) when is_map(labels) do
    labels
    |> Map.to_list()
    |> add_default_metadata()
  end

  defp format_metadata(labels) when is_list(labels) do
    add_default_metadata(labels)
  end

  defp add_default_metadata(metadata) do
    # Add some default metadata that's useful for Axiom
    default_metadata = [
      service: "echo",
      environment: get_environment(),
      node: node()
    ]

    Keyword.merge(default_metadata, metadata)
  end

  defp get_environment do
    Application.get_env(:echo, :environment, @compile_env)
  end
end
