defmodule Echo.Agents.ToolBackend do
  @moduledoc """
  The contract a module implements to be an executable tool.

  Until now this was implicit — `Echo.Agents.Tools` called `declaration/0` and
  `run/1` on whatever was in its registry, and nothing said so. Writing it down
  is what lets `mutating?/1` be relied on rather than probed for.
  """

  @doc """
  Canonical function declaration: standard, lowercase-typed JSON Schema. Each
  provider rewrites it into its own dialect.
  """
  @callback declaration() :: map()

  @doc """
  Runs the call. Returns whatever should become the `functionResponse` body.

  Never raises: a failure comes back as a result the model can read and react
  to, in the same shape as a success.
  """
  @callback run(args :: map()) :: term()

  @doc """
  Whether this call changes anything outside Echo.

  A classification, not a policy — it says what the call *is*, and the
  conversation's tool config decides whether that class stops for a human. That
  split is what keeps gating configuration rather than a policy engine: the
  answer here is fixed and two-valued, and the row picks from a closed set.
  """
  @callback mutating?(args :: map()) :: boolean()
end
