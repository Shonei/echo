defmodule Echo.Agents.Tool do
  @moduledoc """
  One executable tool, resolved for one conversation.

  Built once by `Echo.Agents.Tools.build/2` from durable state and carried on
  the conversation, so the execution path never consults a compile-time
  registry. That indirection is what lets a tool be backed by a row rather than
  a module (Phase 4's pinned code blocks) without touching any call site.
  """

  @typedoc """
  What actually performs the call. A tagged tuple rather than a bare module so
  a future row-backed block is a new tag, not a new shape.
  """
  @type executor :: {:module, module()} | {:code_block, integer()}

  @typedoc """
  When a call stops for a human instead of running.

    * `:never` — runs unattended. The default, and every tool today.
    * `:mutations` — stops only when the tool classifies the call as changing
      something. Reads flow, writes stop.
    * `:always` — stops whatever the arguments are.
  """
  @type gate :: :never | :mutations | :always

  @type t :: %__MODULE__{
          name: String.t(),
          executor: executor(),
          gate: gate(),
          config: map()
        }

  @enforce_keys [:name, :executor]
  defstruct [:name, :executor, gate: :never, config: %{}]
end
