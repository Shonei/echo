# Add OpenRouter as a second model provider (Gemini stays the default)

> **Status: paused.** [`designs/conversation_persistence.md`](./conversation_persistence.md) takes priority — conversations need to survive a process/node restart before it's worth adding a second backend. Resume this once that lands.

## Context

Echo's agent conversations (`Echo.Agents.ConversationServer`, one GenServer per conversation) only ever talk to Gemini. We want to add OpenRouter as a second backend, specifically so conversations can use OpenRouter's `openrouter:web_search` / `openrouter:web_fetch` server tools. Those tools are resolved transparently by OpenRouter itself (no client round-trip) and their results — search hits / fetched page content — surface as `annotations` on the assistant message. The explicit requirement is that Echo's audit trail (the `ai_messages` table) must preserve those annotations, not drop them, mirroring how Gemini's `groundingMetadata`/`urlContextMetadata` already ride along in the `metadata` field that gets both returned to the HTTP caller and persisted today.

**Product decisions:**
1. `Presets.editor/0` and `Presets.photographer/0` stay Gemini-only and unchanged. This is additive infra: the generic `POST /ai/conversation` create endpoint and the internal `/agent-chat` dev UI gain a `provider` option; Blogs (the only real client) never sends `provider` today, so it keeps getting Gemini, unchanged.
2. OpenRouter's docs don't show the exact response JSON for the server tools (only that results land as `annotations`/`url_citation`, and that `usage` carries some tool-use counter whose exact nesting is inconsistent across their own docs pages). Design defensively: capture the `annotations` array and the whole `usage` object into `metadata` rather than parsing a rigid path, and verify the real shape against the live API early in implementation before calling this done.
3. This pass is text + function-tool-calling only for OpenRouter — no image input/output, no `thinking_enabled` mapping. A caller that sets them with `provider: "openrouter"` gets a logged warning, not a silent no-op or a crash.

## Architecture

Keep the existing canonical "part" vocabulary (`text` / `functionCall` / `functionResponse` / `inlineData`, turns shaped `%{"role" => "user"|"model", "parts" => [...]}`) as the one internal representation — it's already what's persisted to `ai_messages`, returned over HTTP, and consumed by Blogs. Each provider module translates canonical <-> its own wire format in both directions. `ConversationServer`'s tool loop, persistence, and iteration cap are untouched because they already only touch canonical parts.

New behaviour, `lib/echo/agents/provider.ex`:
```elixir
@callback generate_content(messages :: [map()], opts :: keyword()) ::
            {:ok, %{parts: [map()], metadata: map()}} | {:error, term()}
@callback build_function_tools(declarations :: [map()]) :: map() | [map()]
```
`generate_content/2` replaces today's raw-JSON return from `Echo.Agents.API.generate_content/3` with already-extracted canonical parts + metadata (moving `ConversationServer`'s private `extract_parts/1` logic into the provider). `build_function_tools/1` takes canonical, standard-lowercase-JSON-Schema tool declarations (what `Echo.Agents.Tools.*.declaration/0` will return from now on) and wraps them the way that provider's wire format expects.

New resolver, `lib/echo/agents/providers.ex`: `resolve(nil | "gemini" | "openrouter")` → `{:ok, module}` / `{:error, {:unknown_provider, name}}`, defaulting to Gemini.

## Renaming `Echo.Agents.API` → `Echo.Agents.Providers.Gemini`

Purely internal rename (only two call sites: `conversation_server.ex` and `test/echo/agents/api_test.exs`; nothing in `blogs` or over HTTP references the module name) so the two backends are visibly symmetric and `@behaviour Echo.Agents.Provider` is explicit. Move `lib/echo/agents/api.ex` → `lib/echo/agents/providers/gemini.ex`:
- Add `@behaviour Echo.Agents.Provider`.
- Keep `list_models/1` and the public `build_payload/2` as-is (still pure, still Gemini-specific utility).
- Move `ConversationServer`'s current `extract_parts/1` (the `candidates[0].content.parts` + grounding/url-context metadata extraction, plus the `finishReason` error branches) in as a private helper called from `generate_content/3` right after JSON decode, so it now returns `{:ok, %{parts:, metadata:}}` per the behaviour.
- Add `build_function_tools/1`: wraps canonical (lowercase-typed) declarations as `%{"functionDeclarations" => [...]}`, recursively upper-casing every `"type"` value in each declaration's `parameters` tree (`"object"` → `"OBJECT"`, `"string"` → `"STRING"`, etc.).
- Fix `format_part/1`'s `functionCall`/`functionResponse` clauses, which currently pass the part through **verbatim**. Once canonical parts can carry an OpenRouter-only `"id"` key, Gemini's request builder must not forward it:
  ```elixir
  defp format_part(%{"functionCall" => call}),
    do: %{"functionCall" => Map.take(call, ["name", "args"])}
  defp format_part(%{"functionResponse" => resp}),
    do: %{"functionResponse" => Map.take(resp, ["name", "response"])}
  ```
- Move/rename `test/echo/agents/api_test.exs` → `test/echo/agents/providers/gemini_test.exs`, update the alias and `API.build_payload` → `Gemini.build_payload` calls only.
- Update the module reference in `config/runtime.exs`, `config/dev.exs`, `config/prod.exs` (env var names `GEMINI_API_KEY`/`GEMINI_MODEL` stay the same, only the `config :echo, Echo.Agents.API, ...` key becomes `config :echo, Echo.Agents.Providers.Gemini, ...`).

## `Conversation` / `ConversationServer` changes

- `Conversation` struct gains a `provider` field.
- `init/1`: resolve `Map.get(opts, :provider) || Map.get(opts, "provider")` via `Echo.Agents.Providers.resolve/1`. On `{:error, reason}`, return `{:stop, reason}`.
- `run_turn/5`: replace the `Echo.Agents.API.generate_content(...)` call + local `extract_parts/1` dispatch with `convo.provider.generate_content(messages, api_opts)`, matching on `{:ok, %{parts: ai_parts, metadata: metadata}}`. Delete the now-dead private `extract_parts/1`. Everything below is untouched.
- `part_to_attrs/1` needs no change: a `functionCall`/`functionResponse` map with an extra `"id"` key still matches its existing clauses and stores the whole map (id included) as `payload`.
- Highest-risk step — run the full test suite right after this change, before adding anything OpenRouter-specific.

## `Echo.Agents.Tools` becoming provider-aware

- `HttpRequest.declaration/0`: switch from Gemini's uppercase-typed shape to canonical, standard-lowercase JSON Schema.
- `tool_config/1` → `tool_config(names, provider \\ Echo.Agents.Providers.Gemini)`.
- `enabled/1` gains a clause for OpenRouter's flat shape: `%{"type" => "function", "function" => %{"name" => name}} -> [name]`.
- `run/1`: carry a `functionCall`'s `"id"` (when present) onto the `functionResponse` it builds.
- `openrouter:web_search`/`openrouter:web_fetch` never flow through this registry at all — they're declared with `"type" => "openrouter:web_search"` (no `"function"`/name), so `enabled/1`'s matching never picks them up, and OpenRouter resolves them server-side within one response.

## New module: `Echo.Agents.Providers.OpenRouter`

Same house style as `s3_client.ex`/the renamed Gemini module: plain module, no process, config read fresh per call. `defstruct [:api_key, :http_client, :log_debug_body]` — no `:model` default; a missing `opts[:model]` is `{:error, :missing_model}`.

**Request building** (`build_payload/2`) walks canonical `messages` into OpenAI-style `messages`:
- System prompt becomes the first `%{"role" => "system", "content" => ...}` message.
- A canonical turn made only of `functionResponse` parts becomes one `role: "tool"` message per part: `%{"role" => "tool", "tool_call_id" => resp["id"], "content" => Jason.encode!(resp["response"])}`.
- A canonical turn with `text`/`functionCall` parts becomes one message with `content` (joined text) and, if any `functionCall` parts, `tool_calls: [%{"id" => ..., "type" => "function", "function" => %{"name" => ..., "arguments" => Jason.encode!(args)}}]` — `arguments` must be a JSON **string**, the opposite of Gemini's map-shaped `args`.
- `build_function_tools/1`: canonical declaration → `%{"type" => "function", "function" => %{...}}`, flat list.

**Response parsing** from `%{"choices" => [%{"message" => message, "finish_reason" => reason}], "usage" => usage}`:
- `message["content"]` → `%{"text" => content}`.
- Each `message["tool_calls"]` entry → `%{"functionCall" => %{"name" => .., "args" => Jason.decode!(arguments), "id" => id}}`.
- `message["annotations"]` → `metadata["annotations"]` verbatim — the audit-preservation requirement, flows straight into the same `metadata` map `async_store_parts/5` already persists.
- `usage` → `metadata["usage"]` verbatim.
- Only `{:error, {:openrouter_error, reason}}` when `finish_reason` is unusual **and** nothing was extracted; otherwise return the partial reply.

## Config

```elixir
config :echo, Echo.Agents.Providers.OpenRouter,
  api_key: System.get_env("OPENROUTER_API_KEY")
```
No default model. Update the three existing `config :echo, Echo.Agents.API, ...` lines to `Echo.Agents.Providers.Gemini`.

## Controllers / router / dev UI

- `ai_conversation_controller.ex`: `create/2` adds `"provider"` to its `Map.take/2` allowlist. `editor/2`/`photographer/2` untouched. No router changes.
- `agent_chat_controller.ex` + `new.html.heex`: provider select, a free-text `openrouter_model` field, a raw-JSON textarea for OpenRouter's native tool syntax (mirrors how `google_search`/`url_context` are already accepted as raw Gemini syntax). `tools/1` resolves the chosen provider and calls `Tools.tool_config(names, provider)`.

## Testing

No Mox or Bypass in `mix.exs`/`mix.lock`, and no test currently overrides `http_client` config to mock the network. Add a small hand-written fake (`test/support/fake_http_client.ex`) exposing `build/4`/`request/3` matching `Finch`'s signatures, injected via `Application.put_env/3` the same way `agent_chat_controller_test.exs` already injects config.

- Pure/unit: `Providers.Gemini.build_payload/2` (moved), `Providers.Gemini.build_function_tools/1`, `Providers.OpenRouter.build_payload/2`, `Providers.OpenRouter.build_function_tools/1`, and — highest value — the response-parsing helper fed hand-built OpenRouter JSON fixtures.
- `Tools.enabled/1`/`Tools.run/1`/`HttpRequest.declaration/0` updates.
- Fake-HTTP-client-backed end-to-end test of `Providers.OpenRouter.generate_content/2`.
- Wiring test extending `agent_chat_controller_test.exs`.

## Implementation order

1. `Echo.Agents.Provider` behaviour + `Echo.Agents.Providers` resolver.
2. Rename `api.ex` → `providers/gemini.ex`, update config + moved test.
3. `Conversation`/`ConversationServer` provider dispatch — run full suite before proceeding.
4. `Tools.enabled/1`, `Tools.run/1`, `HttpRequest.declaration/0`, `Tools.tool_config/2`.
5. `Providers.OpenRouter` module + config + unit tests.
6. Fake HTTP client test seam + end-to-end-ish provider tests.
7. Controller/router/dev-UI changes + tests.
8. Full regression + live manual smoke test against real `OPENROUTER_API_KEY` to confirm the actual server-tool response shape.
