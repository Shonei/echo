# Echo

Echo is a Phoenix application featuring Chat, Request Echoing, and Audit Logging capabilities.

## Local Development

To start your Phoenix server:

1.  **Install dependencies**:
    ```bash
    mix setup
    ```

2.  **Environment Variables** (Optional):
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
| `DATABASE_PATH` | Path to SQLite DB (e.g., `/data/echo.db`) | Yes |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret` | Yes |
| `PHX_HOST` | Domain name (e.g., `myapp.com`) | Yes |
| `AUDIT_PASSWORD` | Password for Audit API | Yes |

### Running a Release

```bash
# 1. Build release
mix release

# 2. Start server
PHX_SERVER=true bin/echo start
```

For detailed deployment steps, see the [Phoenix Deployment Guides](https://hexdocs.pm/phoenix/deployment.html).