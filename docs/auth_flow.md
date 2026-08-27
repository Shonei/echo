# Authentication Flow

This document describes the simple authentication mechanism implemented for the Echo API.

## Configuration

The authentication relies on a single user account configured via environment variables.

-   `USERNAME`: The username for the single user (e.g., "admin").
-   `PASSWORD`: The password for the single user.
-   `JWT_SECRET`: The secret key for signing JWT tokens.

**All three must be set**, or `config :echo, :auth` is never populated and `POST /api/v1/login` returns `500 {"error": "Auth not configured"}`. The same credentials back the HTTP Basic Auth on the browser routes.

(These were named `BLOGS_USERNAME` / `BLOGS_PASSWORD` / `BLOGS_AUTH_SECRET` before commit `dd96f93`.)

## Login

To log in, send a POST request to `/api/v1/login`.

### Request

**Method**: `POST`
**URL**: `/api/v1/login`

**Headers**:
-   `Authorization: Basic <base64(username:password)>`
    -   OR
-   Body parameters: `username` and `password`

### Response

**Success (200 OK)**:

```json
{
  "accessToken": "eyJhbGciOiJIUzI1Ni...",
  "ttl": 28800
}
```

-   `accessToken`: A JWT token signed by the server.
-   `ttl`: Time-to-live in seconds (default: 8 hours).

**Failure (401 Unauthorized)**:

```json
{
  "error": "Invalid credentials"
}
```

## Authenticated Requests

Protected endpoints require the `Authorization` header with the Bearer token.

**Header**: `Authorization: Bearer <accessToken>`

### Protected Endpoints

The following operations require authentication:

-   `POST /api/v1/blogs` (Create Blog)
-   `PUT /api/v1/blogs/:id` (Update Blog)
-   `DELETE /api/v1/blogs/:id` (Delete Blog)
-   `PUT /api/v1/blogs/:blog_id/content` (Update Blog Content)
-   `GET /api/v1/blogs/:blog_id/revisions` (List Revisions)
-   `GET /api/v1/assets` (List Assets)
-   `PUT /api/v1/assets/*path` (Upload Asset)
-   `DELETE /api/v1/assets/*path` (Delete Asset)
-   All of `/api/v1/ai/*` (see `AI_API.md`)

**Not all reads are public.** `GET /api/v1/blogs` and `GET /api/v1/blogs/:id` are the only endpoints that work without a token, and they reveal more with one: anonymous callers see public blogs only. Revision and asset listings require auth like any write.

`GET /api/v1/assets/*path` (serving an asset's bytes) is public — it runs on its own `:assets` pipeline.

## Implementation Details

-   **Token Generation**: Uses `Joken` with HS256 algorithm. TTL is 8 hours, set by `@ttl` in `EchoWeb.LoginController`.
-   **Token handling**:
    -   On login, the token and its expiry are stored in an `Echo.AuthUser` GenServer.
    -   `EchoWeb.Plugs.BearerToken` reads the token from the `Authorization` header on **every** request and validates it against the GenServer state (checking expiry).
    -   The token is **deliberately never written to the Phoenix session**. Promoting it to a cookie would turn a short-lived API credential into a long-lived browser one, readable by anyone who can read the signed-but-unencrypted session cookie. Do not reintroduce that.
    -   `EchoWeb.Plugs.ValidateToken` requires a valid token and halts with `401 {"error": "Unauthorized"}` otherwise.
    -   `EchoWeb.Plugs.MaybeAuthenticate` never halts; it assigns `conn.assigns.authenticated?` so an endpoint can show more to an editor than to an anonymous reader.
