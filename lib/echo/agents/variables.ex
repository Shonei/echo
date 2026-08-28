defmodule Echo.Agents.Variables do
  @moduledoc """
  Late substitution of `$.name` in tool arguments, and the matching scrub of
  resolved values out of tool results.

  Two properties, and everything here exists to hold them:

  1. **The placeholder is what gets persisted.** The model's `functionCall`
     reaches `ai_messages` before the tool loop continues, so the arguments in
     Postgres are the ones the model wrote. `resolve/3` builds a copy for the
     tool to run with, and nothing writes it back. History is replayed into
     every later model request, so a value expanded into it would be re-sent for
     the rest of the conversation's life.

  2. **A sensitive value does not come back in the result.** `scrub/2` puts the
     placeholder back wherever one shows up in what the tool returned, before it
     is persisted or shown to the model. A backstop, not a guarantee: a value
     the tool transformed — encoded, hashed, truncated — will not match and will
     not be caught.
  """

  require Logger

  # `$$.name` escapes to a literal `$.name`, for jq paths and the like.
  @placeholder ~r/(\$\$?)\.([a-z_][a-z0-9_]*)/

  @type pair :: {value :: String.t(), placeholder :: String.t()}

  # --- Scanning ---

  @doc """
  Every variable name referenced anywhere in `term`, deduplicated.

  Order follows traversal, so treat the result as a set. Map keys are not
  scanned.
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
  variable declared `type: number` reaches the tool as `3` rather than `"3"`. A
  reference embedded in a longer string — `"Bearer $.github_api_key"` — is
  always stringified, because there is nothing else it could be.

  A name with no entry in `values` is left exactly as written.
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
    * `{:error, :unresolved, message}` — the model named something that does not
      exist. `message` is model-facing.
    * `{:error, :unavailable, reason}` — the scope could not be answered.
  """
  @spec resolve(map(), String.t() | nil, module() | nil) ::
          {:ok, map(), [pair()]}
          | {:error, :unresolved, String.t()}
          | {:error, :unavailable, term()}
  def resolve(args, scope, resolver)

  # No scope means no variables, so `$.` stays literal text -- in the plain
  # agent chat it is far likelier to be a jq path.
  def resolve(args, nil, _resolver), do: {:ok, args, []}

  def resolve(args, scope, resolver) when is_binary(scope) do
    case scan(args) do
      [] -> {:ok, args, []}
      names -> do_resolve(args, scope, names, resolver)
    end
  end

  # Never fall through and hand the tool `$.token` as a literal.
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
      # A raise here would exit the caller's `GenServer.call`, losing a turn
      # that has already been persisted.
      Logger.error("Variable resolver raised",
        scope: scope,
        error: Exception.message(exception)
      )

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

  Only `:sensitive` binaries are. Replacing a config value would corrupt the
  result rather than protect anything.
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
