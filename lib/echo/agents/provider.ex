defmodule Echo.Agents.Provider do
  @moduledoc """
  The contract every model backend implements.

  Echo has one internal representation of a conversation — the "canonical
  part" vocabulary (`text` / `functionCall` / `functionResponse` /
  `inlineData`, in turns shaped `%{"role" => "user" | "model", "parts" => [...]}`)
  — and it is the only shape `Echo.Agents.ConversationServer` and the
  `ai_messages` table ever handle. A provider translates canonical parts to
  and from its own wire format at the edge, so the tool loop, the persistence
  layer, and the HTTP response Blogs consumes stay identical whichever backend
  answered.

  The vocabulary is Gemini-shaped for historical reasons; that's an accident
  of which backend came first, not a statement that Gemini is special. New
  providers map onto it rather than the other way round.
  """

  @doc """
  Runs one turn and returns already-extracted canonical parts.

  `metadata` is provider-specific and passed through verbatim: Gemini's
  `groundingMetadata`, OpenRouter's `annotations`/`usage`. It is persisted
  alongside the reply and returned to the HTTP caller, so whatever a
  server-side tool surfaced there stays in the audit trail.
  """
  @callback generate_content(messages :: [map()], opts :: keyword()) ::
              {:ok, %{parts: [map()], metadata: map()}} | {:error, term()}

  @doc """
  Wraps canonical tool declarations in this provider's tool syntax.

  Declarations arrive as standard, lowercase-typed JSON Schema (what
  `Echo.Agents.Tools.*.declaration/0` returns); Gemini wants them nested under
  `functionDeclarations` with uppercase types, OpenRouter wants a flat list of
  `%{"type" => "function"}` entries.
  """
  @callback build_function_tools(declarations :: [map()]) :: map() | [map()]
end
