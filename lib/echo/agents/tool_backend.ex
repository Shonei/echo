defmodule Echo.Agents.ToolBackend do
  @moduledoc """
  The contract a module implements to be an executable tool.
  """

  @doc """
  Canonical function declaration: standard, lowercase-typed JSON Schema. Each
  provider rewrites it into its own dialect.
  """
  @callback declaration() :: map()

  @doc """
  Runs the call. Returns whatever should become the `functionResponse` body.

  Never raises: a failure comes back as a result the model can read.
  """
  @callback run(args :: map()) :: term()

  @doc """
  Whether this call changes anything outside Echo.

  A classification, not a policy: the conversation's tool config decides whether
  that class stops for a human.
  """
  @callback mutating?(args :: map()) :: boolean()
end
