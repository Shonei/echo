# Echo — Agent Instructions

## Project Overview

Echo is a **Phoenix 1.8** web application built on **Elixir ~> 1.19** with a **PostgreSQL** database (via `postgrex`). It is a multi-feature platform providing:

- **Real-time Chat** — WebSocket channels (`Phoenix.PubSub`) with AI-powered bot mentions
- **Blog CMS** — CRUD API with revisions, slugs, and content versioning
- **AI Conversation Engine** — Stateful GenServer-backed conversations with the Gemini API, including tool-calling support (server-side and planned client-side)
- **Asset Storage** — S3-compatible file uploads with rate limiting and thumbnail processing (via `vix`/libvips)
- **Audit Logging** — Session-based event tracking with bearer-token auth
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
| `Echo.Agents.API` | Gemini API client (GenServer) |
| `Echo.Agents.ConversationRegistry` | Registry for conversation processes |
| `Echo.Agents.ConversationSupervisor` | DynamicSupervisor for conversation GenServers |
| `Finch` | HTTP client pool |
| `EchoWeb.Endpoint` | Phoenix HTTP/WS endpoint |
| `Echo.AxiomLogger` (conditional) | Axiom log shipping in prod |

### Business Logic Contexts (under `lib/echo/`)

| Context | Modules | Responsibility |
|---|---|---|
| `Echo.Agent` | `Echo.Agent`, `Echo.Agent.Message` | AI message persistence (Ecto schema + CRUD) |
| `Echo.Agents` | `Echo.Agents.API`, `Echo.Agents.ConversationServer`, `Echo.Agents.ConversationManager`, `Echo.Agents.Presets` | Gemini API client, per-conversation GenServers, process lifecycle, pre-configured editor/photographer prompts and tools |
| `Echo.Chat` | `Echo.Chat`, `Echo.Chat.Message` | Chat message CRUD |
| `Echo.ChatRooms` | `Echo.ChatRooms`, `Echo.ChatRooms.ChatRoom` | Chat room management |
| `Echo.Content` | `Echo.Content`, `Echo.Content.Blog`, `Echo.Content.Revision` | Blog + revision CRUD |
| `Echo.Audit` | `Echo.Audit.*` | Audit session/event tracking |
| `Echo.Requests` | `Echo.Requests`, `Echo.Requests.Request`, `Echo.RequestCache`, `Echo.Requests.RequestCleanupJob` | HTTP request echo + cleanup |
| `Echo.Storage` | `Echo.Storage.Assets`, `Echo.Storage.Asset`, `Echo.Storage.S3Client` | S3-compatible asset storage |
| `Echo.AuthUser` | `Echo.AuthUser` | Single-user auth GenServer |
| `Echo.AxiomLogger` / `Echo.AxiomConfig` | — | Structured log shipping |

### Web Layer (under `lib/echo_web/`)

- **Router** (`EchoWeb.Router`) — Defines pipelines: `:browser` (Basic Auth + sessions), `:api` (JSON), `:api_auth` (JWT token extraction/validation), `:echo` (catch-all echo), `:asset_upload` (rate limited)
- **Channels** — `EchoWeb.ChatChannel` handles real-time chat via `chat:<room>` topics
- **Controllers** — Standard Phoenix controllers for each feature (Chat, Blog, AI Conversation, Assets, Audit, Requests, Login, Agent Chat)
- **Plugs** — `AcceptAny`, `AuditAuth`, `ExtractToken`, `ValidateToken`, `RateLimit`
- **Components** — Phoenix components + HEEx templates (Tailwind CSS v3.4)

### Authentication

- **Browser routes** — HTTP Basic Auth (configured via `USERNAME`/`PASSWORD` env vars)
- **API routes** — JWT bearer tokens via `POST /api/v1/login`, validated by `ExtractToken` + `ValidateToken` plugs against the `Echo.AuthUser` GenServer
- **Audit routes** — Separate bearer token (`AUDIT_PASSWORD`)

### Frontend

- **esbuild** bundles `js/app.js` and `js/chat.js`
- **Tailwind CSS 3.4** with a custom `tailwind.config.js`
- **HEEx templates** for server-rendered views
- Standard Phoenix LiveView setup (though most UI is currently controller-rendered)

---

## Key Technical Patterns

### AI Conversation System

Each conversation is a **GenServer** (`Echo.Agents.ConversationServer`) registered in `Echo.Agents.ConversationRegistry` and supervised by `Echo.Agents.ConversationSupervisor` (a `DynamicSupervisor`). Conversations hold message history in process state and interact with the Gemini API through `Echo.Agents.API`. Messages are asynchronously persisted to the database via fire-and-forget `Task.start/1`.

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
| `GEMINI_MODEL` | No | Model override (default: `gemini-3.1-pro-preview`) |
| `USERNAME` | Yes | Basic auth username for browser routes |
| `PASSWORD` | Yes | Basic auth password for browser routes |
| `JWT_SECRET` | Yes | Secret for signing JWT tokens |
| `AUDIT_PASSWORD` | For audit API | Bearer token for audit endpoints |
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
- `AI_CHAT_FEATURE.md` — Design doc for the @mention-based AI chat feature
- `elixir_processes_readme.md` — Educational reference on BEAM processes, linking, and supervision
- `docs/auth_flow.md` — Authentication flow documentation
- `docs/blog_api.md` — Blog API documentation
- `designs/agents_builder.md` — Design doc for the upcoming Agents Builder feature (custom tools + agents)
- `lib/echo_web/agents/geminoi_api_ref.md` — Gemini API reference (local copy)

---

## Active / Planned Work

The **Agents Builder** feature (`designs/agents_builder.md`) is in design phase. It will add:
- Persistent `Agent` and `Tool` Ecto schemas with a many-to-many join
- Server-side tools (HTTP endpoint execution) and client-side tools (browser execution with server handshake)
- A CRUD UI for defining agents and tools
- Integration with the existing `ConversationServer` to inject agent-specific prompts and tool definitions

When working on this feature, pay close attention to the existing conversation infrastructure (`Echo.Agents.*`) and ensure new code integrates cleanly with the existing DynamicSupervisor + Registry pattern.
