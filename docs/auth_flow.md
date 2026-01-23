# Authentication Flow

This document describes the simple authentication mechanism implemented for the Echo API.

## Configuration

The authentication relies on a single user account configured via environment variables.

-   `BLOGS_USERNAME`: The username for the single user (e.g., "admin").
-   `BLOGS_PASSWORD`: The password for the single user.
-   `BLOGS_AUTH_SECRET`: The secret key for signing JWT tokens.

**All environment variables must be set for authentication to work securely.**

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
-   `PUT /api/v1/blogs/:id/content` (Update Blog Content)
-   `PUT /api/v1/assets/*path` (Upload Asset)

Read operations (GET) are public.

## Implementation Details

-   **Token Generation**: Uses `Joken` with HS256 algorithm.
-   **Session Management**:
    -   On login, the token and its expiry are stored in an `Echo.AuthUser` GenServer.
    -   The `ExtractToken` plug extracts the token from the header and puts it into the Phoenix session.
    -   The `ValidateToken` plug checks if the token exists in the session and validates it against the GenServer state (checking expiry).
