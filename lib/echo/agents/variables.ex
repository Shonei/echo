defmodule Echo.Agents.Variables do
  @moduledoc """
  Late substitution of `$.name` in tool arguments, and the matching scrub of
  resolved values out of tool results.

  Two properties, and everything here exists to hold them:

  1. **The placeholder is what gets persisted.** `run_turn/5` writes the model's
     `functionCall` to `ai_messages` before the tool loop continues, so the
     arguments in Postgres are the ones the model wrote. `resolve/3` builds a
     *copy* for the tool to run with, and nothing writes it back — the parts it
     came from are immutable, so it cannot leak upward by accident. History is
     replayed into every later model request (`replay_into_turns/1`), so a value
     expanded into it would be re-sent for the rest of the conversation's life.

  2. **The value does not come back in the result.** `scrub/2` puts the
     placeholder back wherever a resolved value shows up in what the tool
     returned, before the `functionResponse` is persisted or shown to the model.
     A backstop, not a guarantee: a value the tool transformed — encoded,
     hashed, or cut in half by a response-size cap — will not match and will not
     be caught.
  """

  require Logger

  # `$$.name` is the escape: a jq path, or a shell string that genuinely needs
  # the literal text. Without it a skill could never send `$.foo` to a tool at
  # all, and finding that out later means breaking the syntax to fix it.
  @placeholder ~r/(\$\$?)\.([a-z_][a-z0-9_]*)/

  @type pair :: {value :: String.t(), placeholder :: String.t()}

  # --- Scanning ---

  @doc """
  Every variable name referenced anywhere in `term`, deduplicated.

  Order follows traversal, which for a map is term order rather than the order
  the keys were written, so treat the result as a set. `resolve/3` only uses it
  to ask the resolver for names.

  Walks map values and lists. Map *keys* are not scanned: a header name is not
  somewhere a credential belongs, and allowing it would double the substitution
  surface for nothing. Non-strings are ignored.
  """
  @spec scan(term()) :: [String.t()]
  def scan(term), do: term |> collect([]) |> Enum.reverse() |> Enum.uniq()

  defp collect(string, acc) when is_binary(string) do
    @placeholder
    |> Regex.scan(string, capture: :all_but_first)
    |> Enum.reduce(acc, fn
      ["$", name], acc -> [name | acc]
      ["$$", _escaped], acc -> acc
    end)
  end

  defp collect(map, acc) when is_map(map) and not is_struct(map),
    do: Enum.reduce(map, acc, fn {_key, value}, acc -> collect(value, acc) end)

  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_other, acc), do: acc

  # --- Substituting ---

  @doc """
  Replaces every `$.name` in `term` with its value from `values`.

  A string that is *exactly* one reference takes the value's own type, so a
  variable declared `type: number` reaches the tool as `3` rather than `"3"`.
  A reference embedded in a longer string — `"Bearer $.github_api_key"` — is
  always stringified, because there is nothing else it could be.

  A name with no entry in `values` is left exactly as written. `resolve/3`
  refuses the call before reaching here, so in practice that is only a direct
  unit test.
  """
  @spec substitute(term(), %{optional(String.t()) => term()}) :: term()
  def substitute(term, values)

  def substitute("$." <> name = string, values) do
    case Map.fetch(values, name) do
      {:ok, value} -> value
      :error -> interpolate(string, values)
    end
  end

  def substitute(string, values) when is_binary(string), do: interpolate(string, values)

  def substitute(map, values) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, substitute(value, values)} end)

  def substitute(list, values) when is_list(list), do: Enum.map(list, &substitute(&1, values))
  def substitute(other, _values), do: other

  defp interpolate(string, values) do
    Regex.replace(@placeholder, string, fn match, sigil, name ->
      case {sigil, Map.fetch(values, name)} do
        {"$$", _} -> "$." <> name
        {"$", {:ok, value}} -> to_string(value)
        {"$", :error} -> match
      end
    end)
  end

  # --- Resolving ---

  @doc """
  Resolves every placeholder in one call's `args`.

  Returns the arguments the tool should actually run with, plus the
  value/placeholder pairs that were injected — which is exactly what `scrub/2`
  needs to undo them. Both live on the caller's stack and neither is persisted.

    * `{:ok, args, used}` — resolved. `used` may be empty.
    * `{:error, :unresolved, message}` — the model named something that does
      not exist. `message` is model-facing.
    * `{:error, :unavailable, reason}` — the scope could not be answered.

  `resolver` is supplied by the caller rather than looked up here. Nothing in
  this module reads application config, which is what lets every test of it run
  with no setup at all.
  """
  @spec resolve(map(), String.t() | nil, module() | nil) ::
          {:ok, map(), [pair()]}
          | {:error, :unresolved, String.t()}
          | {:error, :unavailable, term()}
  def resolve(args, scope, resolver)

  # No scope means no variables, so `$.foo` is just text — and it has to stay
  # text. `http_request` is already reachable from the plain agent chat, where a
  # `$.` is far likelier to be a jq path than a reference to something that does
  # not exist. Every conversation predating this behaves exactly as it did, and
  # does so without a query.
  def resolve(args, nil, _resolver), do: {:ok, args, []}

  def resolve(args, scope, resolver) when is_binary(scope) do
    case scan(args) do
      [] -> {:ok, args, []}
      names -> do_resolve(args, scope, names, resolver)
    end
  end

  # A conversation carrying a scope with nothing to answer it must not fall
  # through and hand the tool `$.token` as a literal.
  defp do_resolve(_args, _scope, _names, nil),
    do: {:error, :unavailable, :no_resolver}

  defp do_resolve(args, scope, names, resolver) do
    case fetch(resolver, scope, names) do
      {:ok, resolved} ->
        case names -- Map.keys(resolved) do
          [] ->
            values = Map.new(resolved, fn {name, {value, _sensitivity}} -> {name, value} end)
            {:ok, substitute(args, values), merge(pairs(resolved))}

          missing ->
            {:error, :unresolved, unknown_message(missing)}
        end

      {:error, reason} ->
        {:error, :unavailable, reason}
    end
  end

  defp fetch(resolver, scope, names) do
    resolver.fetch(scope, names)
  rescue
    exception ->
      # A resolver blowing up must not take the conversation process with it.
      # An unhandled exit here reaches the caller as a `GenServer.call` exit,
      # which is the "500 for work that completed" failure `@turn_budget_ms`
      # exists to stop.
      Logger.error("Variable resolver raised for #{inspect(scope)}: #{inspect(exception)}")
      {:error, {:resolver_raised, exception}}
  end

  defp unknown_message(missing) do
    named = missing |> Enum.map(&("$." <> &1)) |> Enum.join(", ")

    "Unknown variable(s): #{named}. This skill does not declare them, or they " <>
      "have not been bound. Use only the variables listed in your instructions."
  end

  # --- Scrubbing ---

  @doc """
  Whether a resolved value is replaced in a tool result.

  Only `:sensitive` binaries are. A `:plain` value is left alone on purpose:
  replacing a config value would corrupt the result rather than protect
  anything, and a variable holding `"1"` would rewrite every `1` in every
  result with nothing downstream able to tell.
  """
  @spec scrubbable?(term(), Echo.Agents.VariableResolver.sensitivity()) :: boolean()
  def scrubbable?(value, :sensitive) when is_binary(value), do: value != ""
  def scrubbable?(_value, _sensitivity), do: false

  defp pairs(resolved) do
    for {name, {value, sensitivity}} <- resolved,
        scrubbable?(value, sensitivity),
        do: {value, "$." <> name}
  end

  @doc """
  Collapses pairs from several calls into one scrub set, longest value first.

  Order matters: with `$.base_url` = "https://api.example.com" and `$.host` =
  "api.example.com", undoing the short one first turns the long one into
  "https://$.host", which is both wrong and a lie about what the tool returned.
  """
  @spec merge([pair()]) :: [pair()]
  def merge(pairs) do
    pairs
    |> Enum.uniq()
    |> Enum.sort_by(fn {value, _placeholder} -> -byte_size(value) end)
  end

  @doc """
  Puts placeholders back wherever a resolved value shows up in a tool result.

  Walks the same shapes `substitute/2` does, plus map keys — a tool echoing a
  value into a key is exactly the accident this is a backstop for, and unlike
  substitution there is no cost to being thorough on the way back.
  """
  @spec scrub(term(), [pair()]) :: term()
  def scrub(term, used)

  def scrub(term, []), do: term

  def scrub(string, used) when is_binary(string) do
    Enum.reduce(used, string, fn {value, placeholder}, acc ->
      String.replace(acc, value, placeholder)
    end)
  end

  def scrub(map, used) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {scrub(key, used), scrub(value, used)} end)

  def scrub(list, used) when is_list(list), do: Enum.map(list, &scrub(&1, used))
  def scrub(other, _used), do: other
end
