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
| `DATABASE_PATH` | Old SQLite file to import blog data from, once. See below. | No |

### Migrating from SQLite

This app used to run on SQLite. The first boot after switching to Postgres
imports the blogs, their revisions and the assets from the old file: leave
`DATABASE_PATH` pointing at it and the `20260731110200` migration copies the rows
over, logging a count per table. It runs once, does nothing if the file is
absent, and can be bypassed with `SKIP_SQLITE_IMPORT=true`.

Image bytes live in S3, so nothing outside the database needs moving. Keep the
old file until the import has been verified — it is the only copy. Afterwards,
unset `DATABASE_PATH` and the migration plus `Echo.Release.SqliteImport` can be
deleted along with the `exqlite` dependency.

### Running a Release

```bash
# 1. Build release
mix release

# 2. Start server
PHX_SERVER=true bin/echo start
```

For detailed deployment steps, see the [Phoenix Deployment Guides](https://hexdocs.pm/phoenix/deployment.html).