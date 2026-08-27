# Echo

Echo is a Phoenix application featuring a Blog CMS, stateful AI conversations, S3-backed asset storage, real-time Chat, and Request Echoing.

## Local Development

To start your Phoenix server:

1.  **Start Postgres** and set `POSTGRES_URL` (host, user, password, port, and
    database name in one value). Tests rewrite the database name to `echo_test`
    so they never touch your dev data.

    ```bash
    export POSTGRES_URL=postgres://postgres:postgres@localhost:5432/echo_dev
    ```

2.  **Install dependencies and create the database**:
    ```bash
    mix setup
    ```

3.  **Set auth and AI credentials** (needed for anything past the login page):
    *   `USERNAME`, `PASSWORD`, `JWT_SECRET`: all three required — they gate the
        browser UI and issue API tokens. See [Authentication Flow](docs/auth_flow.md).
    *   `GEMINI_API_KEY`: required for AI features.
    *   `OPENROUTER_KEY`: optional, for conversations on the OpenRouter provider.

4.  **Start the server**:
    ```bash
    mix phx.server
    ```

Visit [`localhost:4000`](http://localhost:4000) in your browser.

## API Endpoints

### JSON API (`/api/v1`)

| Resource | Method | Endpoint | Description | Auth |
|----------|--------|----------|-------------|------|
| **Auth** | POST | `/login` | Exchange credentials for a JWT (8h TTL) | No |
| **Blogs** | GET | `/blogs` | List blogs (public only unless authenticated) | Optional |
| | POST | `/blogs` | Create blog | **Yes** (Bearer) |
| | GET | `/blogs/:id` | Get blog by id or slug (public only unless authenticated) | Optional |
| | PUT | `/blogs/:id` | Update metadata | **Yes** (Bearer) |
| | PUT | `/blogs/:id/content` | Update content (snapshots a revision) | **Yes** (Bearer) |
| | DELETE | `/blogs/:id` | Delete blog | **Yes** (Bearer) |
| **Revisions**| GET | `/blogs/:id/revisions` | List revisions | **Yes** (Bearer) |
| **AI** | POST | `/ai/conversation` | Start a conversation | **Yes** (Bearer) |
| | PUT | `/ai/conversation/:id/message` | Send text, get a reply | **Yes** (Bearer) |
| | PUT | `/ai/conversation/:id/content` | Send content blocks / tool results | **Yes** (Bearer) |
| | DELETE | `/ai/conversation/:id` | End a conversation | **Yes** (Bearer) |
| | POST | `/ai/agents/editor` | Start the blog-editor preset | **Yes** (Bearer) |
| | POST | `/ai/agents/photographer` | Start the photographer preset | **Yes** (Bearer) |
| **Assets** | GET | `/assets` | List assets | **Yes** (Bearer) |
| | GET | `/assets/*path` | Fetch asset bytes | No |
| | PUT | `/assets/*path` | Upload asset (rate limited, 1 per 5s) | **Yes** (Bearer) |
| | DELETE | `/assets/*path` | Delete asset | **Yes** (Bearer) |
| **Echo** | ANY | `/echo/*path` | Capture any request for replay | No |

**Authentication**: For protected endpoints, send `Authorization: Bearer <accessToken>`, where the token comes from `POST /api/v1/login`. See [Authentication Flow](docs/auth_flow.md).

### Documentation

Detailed API documentation can be found in the `docs/` folder:
*   [Blog API](docs/blog_api.md)
*   [Authentication Flow](docs/auth_flow.md)
*   [AI API](AI_API.md) — stateful AI conversations
*   [agents.md](agents.md) — architecture and conventions

### Web Interface

All browser routes are behind HTTP Basic Auth (`USERNAME` / `PASSWORD`).

*   `/chat` - Real-time chat interface.
*   `/assets` - Asset upload and management.
*   `/agent-chat/new` - Start an AI conversation from the browser.
*   `/ai-messages` - Browse stored AI conversations.
*   `/echo/request` - View echoed HTTP requests.

## Production Config

To run in production, set these environment variables:

| Variable | Description | Required |
|----------|-------------|----------|
| `DATABASE_URL` | Postgres connection URL (e.g., `postgres://user:pass@host:5432/echo`) | Yes |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret` | Yes |
| `PHX_HOST` | Domain name (e.g., `myapp.com`) | Yes |
| `USERNAME` / `PASSWORD` | Basic auth for browser routes, and the credentials `POST /api/v1/login` accepts | Yes |
| `JWT_SECRET` | Signs API tokens. Without it, auth is not configured at all | Yes |
| `GEMINI_API_KEY` | Google Gemini API key | For AI features |
| `GEMINI_MODEL` | Default Gemini model (default `gemini-3.1-pro-preview`) | No |
| `OPENROUTER_KEY` | OpenRouter API key, for conversations on that provider | No |
| `S3_SECRET_ACCESS_KEY` | S3 secret key for asset storage | For assets |
| `AXIOM_TOKEN` | Enables structured log shipping to Axiom | No |
| `DATABASE_SSL` | Set to `true` for a managed Postgres that requires TLS | No |
| `POOL_SIZE` | Connection pool size (default `10`) | No |
| `ECTO_IPV6` | Set to `true` to connect over IPv6 | No |

On Railway, `ECTO_IPV6=true` is required: the private network resolves
`*.railway.internal` to an IPv6 address only, so the default IPv4 lookup fails
with `:nxdomain`.

Migrations run at container start, from the `mix ecto.setup` in `nixpacks.toml`.

### Database history

This app ran on SQLite until July 2026. The blogs, their revisions and the assets
were copied into Postgres by a one-off migration on the first boot, which has
since been removed along with the `exqlite` dependency — see commit `d11e9cb` if
it is ever needed again. Image bytes were never in the database (they live in S3),
so nothing outside it moved.

Two consequences worth knowing when reading old migrations: `:string` is
unlimited text on SQLite but `varchar(255)` on Postgres, so `20260731110100`
widens every column that can exceed it; and `requests.body`/`headers`/`url_query`
were declared `:binary` despite holding JSON text, which made them unusable with
`LIKE` on Postgres, so the same migration converts them to `text`.

The audit subsystem was removed in August 2026. Its API routes had already been
dropped in `dd96f93` (March 2026), leaving the context, schemas, `AuditAuth` plug
and `AUDIT_PASSWORD` config unreachable; it backed a CLI agent that was never
wired up. `20260827124508` drops the `audit_sessions` and `audit_events` tables.
Several older migrations still create and alter those tables — they ran before
the drop and are left as-is.

### Running a Release

```bash
# 1. Build release
mix release

# 2. Start server
PHX_SERVER=true bin/echo start
```

For detailed deployment steps, see the [Phoenix Deployment Guides](https://hexdocs.pm/phoenix/deployment.html).