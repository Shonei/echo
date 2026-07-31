# Blog API Documentation

The Blog API allows you to create, read, update, and delete blogs. It also features a revision system that automatically tracks content changes.

## Authentication and visibility

Send `Authorization: Bearer <accessToken>` from `POST /api/v1/login`. The token must be sent on **every** request that needs it — it is not persisted in a cookie.

| Endpoint | Anonymous | Authenticated |
|----------|-----------|---------------|
| `GET /blogs` | Only `status: "public"` blogs. A `?status=` filter is ignored. | All blogs; `?status=` filters. |
| `GET /blogs/:id` | Public blogs only; anything else is `404`. | Any blog. |
| `GET /blogs/:id/revisions` | `401` | Allowed |
| `POST`, `PUT`, `DELETE` | `401` | Allowed |

Unpublished blogs return `404` rather than `403`, so their existence is not disclosed.

## Revisions

Whenever a save replaces a blog's content, the **previous** content is stored as a revision first. Both writes share a transaction, so a blog is never saved without its backup.

No revision is taken when:

*   the save does not change the content, or
*   the blog had no content yet (there is nothing to back up).

Revisions are created only by `PUT /blogs/:id/content` — there is no endpoint for creating one by hand. `PUT /blogs/:id` ignores a `content` key precisely so that content cannot be changed without a snapshot. Revisions are identified by their timestamps rather than a version counter, are returned newest first, and carry the note `"Automatic snapshot before save"`.

## Data Models

### Blog
| Field | Type | Description |
|-------|------|-------------|
| `id` | Integer | Unique identifier |
| `title` | String | Blog title |
| `slug` | String | Unique slug; lowercase letters, numbers and dashes only (`^[a-z0-9]+(?:-[a-z0-9]+)*$`) |
| `status` | String | `draft`, `public`, or `private` |
| `created_at` | Timestamp | Creation date |
| `updated_at` | Timestamp | Last update date |
| `content` | String | Current content |
| `tags` | Object | Map of string keys to string values, e.g. `{"lang": "elixir"}`. Anything else is rejected with `422`. |

A blog is fetched by either numeric `id` or `slug`. A numeric identifier is tried as an id first and then as a slug, so an all-digit slug still resolves.

### Revision
| Field | Type | Description |
|-------|------|-------------|
| `id` | Integer | Unique identifier |
| `blog_id` | Integer | ID of the parent blog |
| `content` | Text | The blog content as it was before the save that replaced it |
| `note` | String | Note describing the change |
| `created_at` | Timestamp | Date of revision; revisions are ordered by this |

---

## Endpoints

Base URL: `/api/v1`

### 1. List Blogs

Returns public blogs, or all blogs when authenticated. Optional `?status=draft|public|private` filter, honoured only for authenticated callers.

*   **URL**: `/blogs`
*   **Method**: `GET`
*   **Auth**: Optional (changes what is returned)
*   **Response**: `200 OK`

```json
{
  "data": [
    {
      "id": 1,
      "title": "My First Post",
      "slug": "my-first-post",
      "status": "public",
      "content": "This is the content.",
      "created_at": "2026-01-13T10:00:00Z",
      "updated_at": "2026-01-13T11:00:00Z"
    }
  ]
}
```

### 2. Create Blog

Creates a new blog. `status` defaults to `draft`.

*   **URL**: `/blogs`
*   **Method**: `POST`
*   **Auth**: Required
*   **Payload**:

```json
{
  "blog": {
    "title": "New Blog Post",
    "slug": "new-blog-post",
    "status": "draft",
    "content": "Initial draft content.",
    "tags": { "lang": "elixir" }
  }
}
```

*   **Response**: `201 Created`
*   **Errors**: `422` if the slug is malformed or already taken, or if `tags` is not a map of strings

### 3. Get Blog

Retrieves a single blog by ID or slug.

*   **URL**: `/blogs/:id`
*   **Method**: `GET`
*   **Auth**: Optional; returns `404` for a non-public blog without it
*   **Response**: `200 OK`

```json
{
  "data": {
    "id": 1,
    "title": "New Blog Post",
    "content": "Initial draft content.",
    ...
  }
}
```

### 4. Update Blog Metadata

Updates a blog's metadata. A `content` key is **ignored** — use endpoint 5 so the replaced content is snapshotted.

*   **URL**: `/blogs/:id`
*   **Method**: `PUT`
*   **Auth**: Required
*   **Payload**:

```json
{
  "blog": {
    "title": "Updated Title",
    "status": "public",
    "tags": { "lang": "elixir" }
  }
}
```

*   **Response**: `200 OK`
*   **Errors**: `400` if the `blog` key is missing; `422` on a malformed slug, duplicate slug, or non-map `tags`

### 5. Update Blog Content

Updates a blog's content. The content being replaced is automatically saved as a revision first.

*   **URL**: `/blogs/:id/content`
*   **Method**: `PUT`
*   **Auth**: Required
*   **Payload**:

```json
{
  "content": "This is new content."
}
```

*   **Response**: `200 OK`
*   **Errors**: `400` if the `content` key is missing; `422` if `content` is not a string

### 6. Delete Blog

Deletes a blog and all its associated revisions.

*   **URL**: `/blogs/:id`
*   **Method**: `DELETE`
*   **Auth**: Required
*   **Response**: `204 No Content`

### 7. List Revisions

Get the revision history for a specific blog, newest first.

*   **URL**: `/blogs/:id/revisions`
*   **Method**: `GET`
*   **Auth**: Required
*   **Response**: `200 OK`

```json
{
  "data": [
    {
      "id": 2,
      "blog_id": 1,
      "content": "The content this save replaced",
      "note": "Automatic snapshot before save",
      "created_at": "..."
    }
  ]
}
```

There is no endpoint for creating a revision by hand; they are only produced by endpoint 5.
