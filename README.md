# Echo

Echo is a Phoenix application featuring Chat, Request Echoing, and Audit Logging capabilities.

## Local Development

To start your Phoenix server:

1.  **Start Postgres** (any instance will do):
    ```bash
    docker run -d --name echo-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16
    ```
    Connection details default to `postgres:postgres@localhost:5432` and can be
    overridden with `PGUSER`, `PGPASSWORD`, `PGHOST` and `PGPORT`.

2.  **Install dependencies and create the database**:
    ```bash
    mix setup
    ```

3.  **Environment Variables** (Optional):
    *   `AUDIT_PASSWORD`: Master password for Audit API (POST requests).


3.  **Start the server**:
    ```bash
    mix phx.server
    ```

Visit [`localhost:4000`](http://localhost:4000) in your browser.

## API Endpoints

### JSON API (`/api/v1`)

| Resource | Method | Endpoint | Description | Auth |
|----------|--------|----------|-------------|------|
| **Audit** | POST | `/audit/sessions` | Create session | **Yes** (Bearer) |
| | POST | `/audit/events` | Log event | **Yes** (Bearer) |
| | GET | `/audit/sessions` | List sessions | No |
| | GET | `/audit/sessions/:id/events` | List events | No |
| **Chat** | GET | `/chat/rooms` | List rooms | No |
| | GET | `/chat/:room/messages` | Get messages | No |
| | POST | `/chat/:room/messages` | Post message | No |
| **Rooms** | GET | `/rooms` | List rooms | No |
| | POST | `/rooms` | Create room | No |
| **Blogs** | GET | `/blogs` | List blogs (public only unless authenticated) | Optional |
| | POST | `/blogs` | Create blog | **Yes** (Bearer) |
| | GET | `/blogs/:id` | Get blog by id or slug (public only unless authenticated) | Optional |
| | PUT | `/blogs/:id` | Update metadata | **Yes** (Bearer) |
| | PUT | `/blogs/:id/content` | Update content (snapshots a revision) | **Yes** (Bearer) |
| | DELETE | `/blogs/:id` | Delete blog | **Yes** (Bearer) |
| **Revisions**| GET | `/blogs/:id/revisions` | List revisions | **Yes** (Bearer) |

**Authentication**: For protected endpoints, send the header `Authorization: Bearer <AUDIT_PASSWORD>`.

### Documentation

Detailed API documentation can be found in the `docs/` folder:
*   [Blog API](docs/blog_api.md)

### Web Interface
*   `/chat` - Real-time chat interface.
*   `/echo/request` - View echoed HTTP requests.

## Production Config

To run in production, set these environment variables:

| Variable | Description | Required |
|----------|-------------|----------|
| `DATABASE_URL` | Postgres connection URL (e.g., `postgres://user:pass@host:5432/echo`) | Yes |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret` | Yes |
| `PHX_HOST` | Domain name (e.g., `myapp.com`) | Yes |
| `AUDIT_PASSWORD` | Password for Audit API | Yes |
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

### Running a Release

```bash
# 1. Build release
mix release

# 2. Start server
PHX_SERVER=true bin/echo start
```

For detailed deployment steps, see the [Phoenix Deployment Guides](https://hexdocs.pm/phoenix/deployment.html).