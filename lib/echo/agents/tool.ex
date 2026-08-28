defmodule Echo.Agents.Tool do
  @moduledoc """
  One executable tool, resolved for one conversation by
  `Echo.Agents.Tools.build/2` and carried on it.
  """

  @typedoc """
  What actually performs the call. Tagged so a tool need not be a module.
  """
  @type executor :: {:module, module()}

  @typedoc """
  When a call stops for a human instead of running.

    * `:never` — runs unattended. The default.
    * `:mutations` — stops when the tool classifies the call as mutating.
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
