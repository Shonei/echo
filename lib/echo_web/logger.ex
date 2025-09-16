defmodule Echo.Logger do
  require Logger

  def info(message, labels \\ %{}) do
    Logger.info(%{msg: message, labels: labels})
  end

  def error(message, labels \\ %{}) do
    Logger.error(%{msg: message, labels: labels})
  end

  def warn(message, labels \\ %{}) do
    Logger.warn(%{msg: message, labels: labels})
  end

  def debug(message, labels \\ %{}) do
    Logger.debug(%{msg: message, labels: labels})
  end
end
