# Echo — Agent Instructions

## Project Overview

Echo is a **Phoenix 1.8** web application built on **Elixir ~> 1.19** with a **PostgreSQL** database (via `postgrex`). It is a multi-feature platform providing:

- **Real-time Chat** — WebSocket channels (`Phoenix.PubSub`) with rooms and message history
- **Blog CMS** — CRUD API with revisions, slugs, and content versioning
- **AI Conversation Engine** — GenServer-backed conversations, durable and resumable from Postgres, over a pluggable provider (Gemini by default, OpenRouter available), with server-executed tools (`Echo.Agents.Tools`) and client-executed tools (declared by the caller, returned for it to run)
- **Asset Storage** — S3-compatible file uploads with rate limiting and thumbnail processing (via `vix`/libvips)
- **Request Echoing** — HTTP request capture and replay for debugging
- **Axiom Logging** — Optional structured log shipping to Axiom in production

The app is deployed via **Nixpacks** (e.g., Railway) and uses **Bandit** as the HTTP server.

---

## Architecture

### Supervision Tree (`Echo.Application`)

The app boots the following supervised children:

| Child | Purpose |
|---|---|
| `EchoWeb.Telemetry` | Telemetry metrics |
| `Echo.Repo` | Ecto/Postgres repo |
| `Ecto.Migrator` | Auto-runs migrations on boot |
| `DNSCluster` | Clustering (production) |
| `Phoenix.PubSub` | PubSub backbone for channels |
| `Echo.RequestCache` | ETS-backed request echo cache |
| `Echo.Requests.RequestCleanupJob` | Periodic cleanup of old HTTP requests |
| `EchoWeb.Plugs.RateLimit.TableOwner` | ETS owner for rate limit counters |
| `Echo.AuthUser` | Single-user auth state (GenServer) |
| `Echo.Agents.ConversationRegistry` | Registry for conversation processes |
| `Echo.Agents.ConversationSupervisor` | DynamicSupervisor for conversation GenServers |
| `Echo.Skills.RunSupervisor` | Task.Supervisor for skill runs (`:temporary` children, capped) |
| `Finch` | HTTP client pool |
| `EchoWeb.Endpoint` | Phoenix HTTP/WS endpoint |
| `Echo.AxiomLogger` (conditional) | Axiom log shipping in prod |

Model providers are deliberately *not* in this tree. `Echo.Agents.Providers.Gemini`
and `Echo.Agents.Providers.OpenRouter` are plain modules holding no process and no
state: each call reads config fresh and makes its request on the caller's process,
so concurrent conversations run in parallel instead of queueing behind one shared
GenServer.

### Business Logic Contexts (under `lib/echo/`)

| Context | Modules | Responsibility |
|---|---|---|
| `Echo.Agent` | `Echo.Agent`, `Echo.Agent.Message`, `Echo.Agent.ConversationRecord` | Durable conversation state: message rows (`ai_messages`) and per-conversation config (`ai_conversations`) |
| `Echo.Agents` | `Echo.Agents.ConversationServer`, `Echo.Agents.ConversationManager`, `Echo.Agents.Provider`, `Echo.Agents.Providers`, `Echo.Agents.Providers.Gemini`, `Echo.Agents.Providers.OpenRouter`, `Echo.Agents.Presets`, `Echo.Agents.Tools`, `Echo.Agents.Tools.HttpRequest`, the skill-authoring tools, `Echo.Agents.Tool`, `Echo.Agents.ToolBackend`, `Echo.Agents.Variables`, `Echo.Agents.VariableResolver` | Per-conversation GenServers, process lifecycle, the provider behaviour and its backends, pre-configured editor/photographer prompts and tools, server-executed tools and their per-conversation settings, late `$.name` substitution into tool arguments |
| `Echo.Chat` | `Echo.Chat`, `Echo.Chat.Message` | Chat message CRUD |
| `Echo.ChatRooms` | `Echo.ChatRooms`, `Echo.ChatRooms.ChatRoom` | Chat room management |
| `Echo.Content` | `Echo.Content`, `Echo.Content.Blog`, `Echo.Content.Revision` | Blog + revision CRUD |
| `Echo.Requests` | `Echo.Requests`, `Echo.Requests.Request`, `Echo.RequestCache`, `Echo.Requests.RequestCleanupJob` | HTTP request echo + cleanup |
| `Echo.Skills` | `Echo.Skills`, `Echo.Skills.Skill`, `Echo.Skills.Run`, `Echo.Skills.Variable`, `Echo.Skills.Variables`, `Echo.Skills.SkillTools`, `Echo.Skills.Runner` | Skills as rows: instructions + tool names + generation config, run unattended as ordinary conversations |
| `Echo.Storage` | `Echo.Storage.Assets`, `Echo.Storage.Asset`, `Echo.Storage.S3Client` | S3-compatible asset storage |
| `Echo.AuthUser` | `Echo.AuthUser` | Single-user auth GenServer |
| `Echo.AxiomLogger` / `Echo.AxiomConfig` | — | Structured log shipping |

### Web Layer (under `lib/echo_web/`)

- **Router** (`EchoWeb.Router`) — Defines pipelines: `:browser` (Basic Auth + sessions), `:api` (JSON), `:api_auth` (JWT extraction/validation), `:api_maybe_auth` (optional auth, for public-or-private reads), `:basic_auth` (Basic Auth on a JSON route), `:echo` (catch-all echo), `:assets` (asset reads), `:asset_upload` / `:rate_limit_uploads` (uploads, rate limited)
- **Channels** — `EchoWeb.ChatChannel` handles real-time chat via `chat:<room>` topics
- **Controllers** — Standard Phoenix controllers for each feature (Chat, Blog, AI Conversation, Assets, Requests, Login, Agent Chat)
- **Plugs** — `AcceptAny`, `BearerToken`, `ValidateToken`, `MaybeAuthenticate`, `CacheRawBody`, `RateLimit`
- **Components** — Phoenix components + HEEx templates (Tailwind CSS v3.4)

### Authentication

- **Browser routes** — HTTP Basic Auth (configured via `USERNAME`/`PASSWORD` env vars)
- **API routes** — JWT bearer tokens via `POST /api/v1/login`, validated by `BearerToken` + `ValidateToken` plugs against the `Echo.AuthUser` GenServer

### Frontend

- **esbuild** bundles `js/app.js` and `js/chat.js`
- **Tailwind CSS 3.4** with a custom `tailwind.config.js`
- **HEEx templates** for server-rendered views
- Standard Phoenix LiveView setup (though most UI is currently controller-rendered)

---

## Key Technical Patterns

### AI Conversation System

Each conversation is a **GenServer** (`Echo.Agents.ConversationServer`) registered by id in
`Echo.Agents.ConversationRegistry` and supervised by `Echo.Agents.ConversationSupervisor`
(a `DynamicSupervisor`). `Echo.Agents.ConversationManager` is the API boundary — nothing
outside `Echo.Agents` should touch the registry or the supervisor directly.

**Postgres is the source of truth; the process is a cache.** This is the spine of the
design, and most of the non-obvious code follows from it:

- A conversation's config lives in `ai_conversations` (`Echo.Agent.ConversationRecord`)
  and its history in `ai_messages` (`Echo.Agent.Message`). `start_conversation/1` writes
  the config row *before* starting the process.
- `ConversationServer.init/1` takes **only** an `:id`. Prompt, temperature, tools,
  provider, and full message history are all loaded back from the database — which
  makes "create" and "resume" the same code path.
- `ConversationManager.with_process/2` therefore resumes transparently: a registry miss
  just starts a child, and `init/1` rehydrates. A redeploy wipes the registry
  (every push to `elixir` goes straight to prod) and callers never notice. If no durable
  record exists, `init/1` stops with `:conversation_not_found`.
- `kill_conversation/1` must delete the durable record, not just the process, or the next
  message to that id would silently resurrect the "deleted" conversation.

Persistence is **synchronous and fails the turn** — see `store_parts/5`. It is not
fire-and-forget: a resumed conversation is only as trustworthy as what actually landed in
Postgres, so a write failure surfaces to the caller rather than being logged and dropped.
For the same reason, the error tuple from `run_turn/5` carries the message list that was
*actually persisted* — never more — so in-memory state and durable state cannot diverge.

Note that a conversation's system prompt is written exactly once, by
`Echo.Agent.create_conversation/2`, and is skipped when replaying history. Writing it
anywhere else would duplicate it on every restart.

### Providers

`Echo.Agents.Provider` is a two-callback behaviour (`generate_content/2`,
`build_function_tools/1`). `Echo.Agents.Providers` resolves a name to a module;
`nil` means the default (Gemini), not "invalid".

Echo has **one internal representation** of a conversation — the canonical part
vocabulary: `text` / `functionCall` / `functionResponse` / `inlineData`, in turns shaped
`%{"role" => "user" | "model", "parts" => [...]}`. That is the only shape
`ConversationServer` and the `ai_messages` table ever handle. A provider translates to and
from its own wire format at the edge, so the tool loop, persistence, and the HTTP response
Blogs consumes are identical whichever backend answered.

The vocabulary is Gemini-shaped for historical reasons — an accident of which backend came
first, not a statement that Gemini is special. **New providers map onto it, not the other
way round.** Two mismatches the OpenRouter provider absorbs, as examples of what that
means in practice: it pairs a tool call with its result by `id` rather than by name (so
the id rides along on the canonical parts and is persisted), and its tool arguments are a
JSON *string* where Gemini's `args` is a map.

A conversation's provider is fixed at creation and stored on its `ConversationRecord`.
It is read from that record on every resume, never from `opts` — a provider held only in
memory would quietly revert to the default the first time the process was rebuilt.

### Phoenix Contexts

The project follows the standard Phoenix context pattern — business logic lives in context modules under `lib/echo/`, and web concerns (controllers, channels, plugs) live under `lib/echo_web/`. Ecto schemas are nested inside their context directories.

### Database

PostgreSQL via `postgrex`. Migrations live in `priv/repo/migrations/`. The database auto-migrates on application boot (via `Ecto.Migrator` in the supervision tree).

The app ran on SQLite until July 2026. Blog data was copied over by a one-off migration that has since been removed (see commit `d11e9cb`). Note that `20260731110100_widen_text_columns` exists because Ecto's `:string` is unlimited text on SQLite but `varchar(255)` on Postgres.

---

## Development Commands

```bash
# Install dependencies and set up DB
mix setup

# Start the dev server (localhost:4000)
mix phx.server

# Run tests
mix test

# Format code
mix format

# Generate a migration
mix ecto.gen.migration <name>

# Reset database
mix ecto.reset

# Build assets for production
mix assets.deploy
```

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `GEMINI_API_KEY` | Yes (for AI features) | Google Gemini API key |
| `GEMINI_MODEL` | No | Default model for Gemini conversations (default: `gemini-3.1-pro-preview`) |
| `OPENROUTER_KEY` | For OpenRouter conversations | OpenRouter API key. There is deliberately no default model — an OpenRouter conversation must name its own |
| `USERNAME` | Yes | Basic auth username for browser routes |
| `PASSWORD` | Yes | Basic auth password for browser routes |
| `JWT_SECRET` | Yes | Secret for signing JWT tokens |
| `S3_SECRET_ACCESS_KEY` | For assets | S3 secret key for asset storage |
| `DATABASE_URL` | Prod only | Postgres connection URL |
| `DATABASE_SSL` | Optional | Set to `true` when the Postgres provider requires TLS |
| `ECTO_IPV6` | Railway | Required on Railway: private network is IPv6-only |
| `SECRET_KEY_BASE` | Prod only | Phoenix secret key base |
| `PHX_HOST` | Prod only | Production hostname |
| `AXIOM_TOKEN` | Prod only | Axiom logging token |

---

## Code Style & Conventions

- **Formatter**: Always run `mix format` before committing. The project uses the standard `.formatter.exs` with Phoenix and Ecto imports.
- **Context pattern**: Business logic goes in context modules (`Echo.Content`, `Echo.Chat`, etc.), not in controllers.
- **Ecto schemas**: Live inside their context directory (e.g., `lib/echo/content/blog.ex`).
- **Controllers**: Use `action_fallback EchoWeb.FallbackController` for error handling where appropriate.
- **JSON views**: Named `*_json.ex` (e.g., `blog_json.ex`), colocated with controllers.
- **Tests**: Use `Ecto.Adapters.SQL.Sandbox` for database isolation. Test support modules live in `test/support/`.

---

## Elixir Guidance — IMPORTANT

**The project owner is not an Elixir expert.** When working on this project, you must:

1. **Question Elixir decisions.** If the user proposes an approach that is non-idiomatic, suboptimal, or potentially dangerous in Elixir/OTP, do not silently comply. Instead:
   - Explain *why* the approach is problematic
   - Suggest the idiomatic alternative
   - Provide concrete examples or links to Elixir docs

2. **Watch for common pitfalls.** Proactively flag issues like:
   - Using raw `spawn` or `Task.start` when a supervised process is appropriate
   - Storing mutable state outside of GenServers/ETS/the database
   - Blocking the caller process with long-running synchronous calls
   - Missing error handling on GenServer calls (timeouts, process crashes)
   - N+1 query patterns in Ecto
   - Improper use of `Repo.insert!/update!` (raising versions) vs `Repo.insert/update` (tuple returns) — prefer the non-raising versions and pattern match on the result
   - Misuse of atoms (dynamic atom creation from user input is a memory leak)
   - Not leveraging pattern matching and guard clauses where they simplify code
   - String concatenation with `<>` in queries instead of Ecto query composition

3. **Explain OTP concepts when relevant.** If a task involves GenServers, Supervisors, Registries, or process linking, provide brief context on how the OTP mechanism works and why the chosen approach is correct (or not).

4. **Recommend Phoenix conventions.** Guide toward:
   - Using contexts for business logic separation
   - Proper changeset validation
   - Idiomatic Plug pipeline composition
   - Phoenix.PubSub for cross-process communication instead of direct message passing
   - Ecto.Multi for transactional multi-step operations

5. **Be opinionated about correctness over convenience.** It is better to push back on a quick hack and explain the right way, than to silently implement something that will cause issues later. The user *wants* to learn — treat every Elixir-related discussion as a teaching opportunity.

---

## Existing Documentation

The project has additional documentation that may be useful for context:

- `AI_API.md` — Full API reference for the AI conversation endpoints
- `elixir_processes_readme.md` — Educational reference on BEAM processes, linking, and supervision
- `docs/auth_flow.md` — Authentication flow documentation
- `docs/blog_api.md` — Blog API documentation
- `docs/skills_api.md` — Skills API documentation, including the builder agent
- `designs/conversation_persistence.md` — Durable, resumable conversations (**implemented**)
- `designs/openrouter_provider.md` — OpenRouter as a second provider (**implemented**)
- `designs/skills.md` — Repeatable agent work, authored by an agent (**Phase 1 implemented**, Phases 2–9 proposed)
- `lib/echo_web/agents/geminoi_api_ref.md` — Gemini API reference (local copy)

---

## Tools

A conversation can carry three kinds of tool, all passed through the same `tools` option:

| Kind | Declared by | Executed by | Examples |
|---|---|---|---|
| Provider built-ins | Gemini: `%{"google_search" => %{}}`, `%{"url_context" => %{}}`. OpenRouter: `%{"type" => "openrouter:web_search"}`, `%{"type" => "openrouter:web_fetch"}` | The provider, server-side, with no round-trip to Echo | Web search, URL fetching |
| Echo tools | `Echo.Agents.Tools.tool_config/2` | `Echo.Agents.ConversationServer`, before it replies | `http_request` |
| Client tools | The API caller's own `functionDeclarations` | The caller, after the reply comes back | The blog editor's `edit_text`, `insert_lines` |

All three kinds can be combined in one conversation, but only on text models.
Image-generating models (`gemini-3-pro-image-preview`) cannot call tools at all, which is
why the `photographer` preset declares none. Note that an empty `tools` list is not the
same as no tools: sending `"tools": []` to an image model makes Gemini fail, so
`nil` is what must reach the provider.

Echo tool declarations are written **once**, in canonical lowercase-typed JSON Schema
(`Echo.Agents.Tools.*.declaration/0`). Each provider rewrites them into its own dialect
via `build_function_tools/1` — Gemini nests them under `functionDeclarations` and
upper-cases every type, OpenRouter takes a flat list of `%{"type" => "function"}` entries
and leaves the types alone. The same tool therefore works on any backend.

Mixing built-in tools with function declarations requires
`toolConfig.includeServerSideToolInvocations`, or Gemini rejects the request with a 400:
*"Please enable tool_config.include_server_side_tool_invocations to use Built-in tools with
Function calling."* `Echo.Agents.Providers.Gemini.build_payload/2` sets it automatically
whenever both kinds are present, and `test/echo/agents/providers_gemini_test.exs` pins
that — do not remove it.

`Echo.Agents.Tools` is the registry of the middle kind. When a reply contains a
`functionCall` for a registered tool, `run_turn/5` in `ConversationServer` runs it,
appends the `functionResponse` as a user turn, and calls the provider again — up to
`@max_tool_iterations` (5) times per user message. The caller sees the tool calls
in the returned parts and the final answer, and every step is persisted to
`ai_messages` before the next model call is made.

Execution is gated on `Echo.Agents.Tools.enabled/1`, which reads the tools the
conversation actually declared. A model can emit a call for a tool it was never
offered, and in a conversation that only declared client-side tools Echo must not
run it. The same gate is what keeps OpenRouter's own server-side tools out of Echo's
loop: they carry no `"function"` key, so they never match — which is correct, because
OpenRouter resolves them itself and returns the results as `annotations` in `metadata`.

`Echo.Agents.Tools.HttpRequest` (`http_request`) lets the model make an arbitrary
HTTP request. Because the model picks the URL, `validate_url/1` refuses non-HTTP
schemes and any host resolving to a loopback, private, link-local, CGNAT,
multicast, or reserved address — the cloud metadata endpoint included — and
responses are capped at 512 KB. It is off unless ticked on in the agent-chat form.

---

## Active / Planned Work

**Skills** (`designs/skills.md`) is proposed, nothing is built. It supersedes the earlier
Agents Builder design (DB-defined agents with HTTP-endpoint tools), which was never
implemented and has been removed; the pieces worth keeping are folded into the skills doc.

When working on it, pay close attention to the existing conversation infrastructure
(`Echo.Agents.*`) and ensure new code integrates cleanly with the DynamicSupervisor +
Registry pattern — and with the rule that Postgres, not process state, is the source of
truth for anything a conversation must survive a redeploy with.
