defmodule Echo.Agents.VariableResolver do
  @moduledoc """
  The one thing `Echo.Agents` needs from whatever owns a conversation's
  variables, and the only thing it is allowed to know about it.

  `Echo.Skills` calls `Echo.Agents.ConversationManager` to start a run, so
  `Echo.Agents` cannot name `Echo.Skills` back without a compile-time cycle.
  The implementing module is read from application config
  (`config :echo, :variable_resolver, Echo.Skills.Variables`) instead. Config is
  data, and a module name sitting in it is not a dependency — that lookup, not
  the behaviour below, is what breaks the cycle. The behaviour is here for
  `@impl` checking and for somewhere to write this down.

  The callback is deliberately the smallest thing that can cross: names in,
  values out. Finding placeholders, substituting them, and scrubbing them back
  out of a tool result are pure and live in `Echo.Agents.Variables`, where they
  are testable without a skill, a database, or a model. Code that decides what
  a secret is worth protecting should not need a fixture.

  Taking `names` rather than returning every binding matters more in Phase 6
  than it does now: a secret the call never referenced is never read.
  """

  @typedoc """
  What a variable resolves to. `skill_variables.type` is what picks between
  these; a value is a string unless the declaration says otherwise.
  """
  @type value :: String.t() | number() | boolean()

  @typedoc """
  How hard a value must be kept out of the transcript.

  `:sensitive` is replaced by its placeholder in a tool result. `:plain` is
  left alone: scrubbing a config value would corrupt results rather than
  protect anything — a variable holding `"1"` would rewrite every `1` in every
  result, silently, and nothing downstream could tell.

  Phase 1 has only `config` and `input` variables and returns `:plain` for
  both, so scrubbing is a tested no-op. Phase 6's `secret` and Phase 7's
  `oauth` return `:sensitive`, and nothing in `Echo.Agents` changes.
  """
  @type sensitivity :: :plain | :sensitive

  @typedoc "An opaque token naming where this conversation's values come from."
  @type scope :: String.t()

  @doc """
  Resolves `names` within `scope`.

  Returns only what it could resolve. A name missing from the map is reported
  to the model as unknown, so "never declared" and "declared but never bound"
  look the same — which is what they are from where the model sits, and it
  means one error path rather than two.

  `{:error, reason}` means the *scope* could not be answered at all: deleted,
  or its store unreachable. That fails the turn rather than reaching the model,
  because telling a model its credential is unavailable invites it to
  improvise around it.
  """
  @callback fetch(scope(), names :: [String.t()]) ::
              {:ok, %{optional(String.t()) => {value(), sensitivity()}}} | {:error, term()}
end
