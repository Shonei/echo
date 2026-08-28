defmodule Echo.Agents.VariableResolver do
  @moduledoc """
  Turns variable names into values for a conversation.

  `Echo.Agents` is generic and `Echo.Skills` is one consumer of it, so the
  contract lives here and the implementation lives there;
  `Echo.Agents.ConversationManager` hands the module to each conversation at
  start. That works because there is one resolver for the whole system --
  anything varying per conversation has to be durable, which is why the scope
  is a column.
  """

  @typedoc """
  What a variable resolves to. `skill_variables.type` is what picks between
  these; a value is a string unless the declaration says otherwise.
  """
  @type value :: String.t() | number() | boolean()

  @typedoc """
  Whether a value is kept out of the transcript.

  `:sensitive` is replaced by its placeholder in a tool result; `:plain` is left
  alone, because replacing a config value would corrupt results rather than
  protect anything.
  """
  @type sensitivity :: :plain | :sensitive

  @typedoc "An opaque token naming where this conversation's values come from."
  @type scope :: String.t()

  @doc """
  Resolves `names` within `scope`.

  Returns only what it could resolve. A name missing from the map is reported to
  the model as unknown, so "never declared" and "declared but never given a
  value" look the same — which is what they are from where the model sits, and
  it means one error path rather than two.

  `{:error, reason}` means the *scope* could not be answered at all: deleted, or
  its store unreachable. That fails the turn rather than reaching the model,
  because telling a model its credential is unavailable invites it to improvise
  around it.
  """
  @callback fetch(scope(), names :: [String.t()]) ::
              {:ok, %{optional(String.t()) => {value(), sensitivity()}}} | {:error, term()}
end
