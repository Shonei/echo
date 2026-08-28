defmodule Echo.AxiomLoggerHandler do
  @moduledoc """
  A logger handler that forwards log events to the AxiomLogger GenServer.

  This handler implements the Erlang logger handler behavior and forwards
  all log events to the AxiomLogger GenServer for processing.
  """

  @behaviour :logger_handler

  def init(_name, _config) do
    {:ok, %{}}
  end

  def log(log_event, state) do
    %{level: level, msg: msg, meta: meta} = log_event

    # Forward to the AxiomLogger GenServer
    Echo.AxiomLogger.log(level, msg, meta)

    state
  end

  def terminate(_reason, _state) do
    :ok
  end
end
