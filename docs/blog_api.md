# Blog API Documentation

The Blog API allows you to create, read, update, and delete blogs. It also features a revision system that automatically tracks content changes.

## Data Models

### Blog
| Field | Type | Description |
|-------|------|-------------|
| `id` | Integer | Unique identifier |
| `title` | String | Blog title |
| `slug` | String | Unique URL-friendly slug |
| `status` | String | `draft`, `public`, or `private` |
| `created_at` | Timestamp | Creation date |
| `updated_at` | Timestamp | Last update date |
| `content` | String | Current content |
| `tags` | String | Comma-separated tags (JSON string) |

### Revision
| Field | Type | Description |
|-------|------|-------------|
| `id` | Integer | Unique identifier |
| `blog_id` | Integer | ID of the parent blog |
| `version` | Integer | Version number |
| `content` | Text | The blog content at this version |
| `note` | String | Optional note describing the change |
| `created_at` | Timestamp | Date of revision |

---

## Endpoints

Base URL: `/api/v1`

### 1. List Blogs

Returns a list of all blogs.

*   **URL**: `/blogs`
*   **Method**: `GET`
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

Creates a new blog.

*   **URL**: `/blogs`
*   **Method**: `POST`
*   **Payload**:

```json
{
  "blog": {
    "title": "New Blog Post",
    "slug": "new-blog-post",
    "status": "draft",
    "content": "Initial draft content."
  }
}
```

*   **Response**: `201 Created`

### 3. Get Blog

Retrieves a single blog by ID.

*   **URL**: `/blogs/:id`
*   **Method**: `GET`
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

Updates a blog's metadata (title, slug, status, tags).

*   **URL**: `/blogs/:id`
*   **Method**: `PUT`
*   **Payload**:

```json
{
  "blog": {
    "title": "Updated Title",
    "status": "public",
    "tags": "tech,elixir"
  }
}
```

*   **Response**: `200 OK`

### 5. Update Blog Content

Updates a blog's content.

*   **URL**: `/blogs/:id/content`
*   **Method**: `PUT`
*   **Payload**:

```json
{
  "content": "This is new content."
}
```

*   **Response**: `200 OK`

### 6. Delete Blog

Deletes a blog and all its associated revisions.

*   **URL**: `/blogs/:id`
*   **Method**: `DELETE`
*   **Response**: `204 No Content`

### 7. List Revisions

Get the revision history for a specific blog.

*   **URL**: `/blogs/:id/revisions`
*   **Method**: `GET`
*   **Response**: `200 OK`

```json
{
  "data": [
    {
      "id": 2,
      "version": 2,
      "content": "Old content version 2",
      "note": "Backup",
      "created_at": "..."
    }
  ]
}
```

### 8. Create Revision

Creates a new revision (snapshot) for a blog.

*   **URL**: `/blogs/:id/revisions`
*   **Method**: `POST`
*   **Payload**:

```json
{
  "revision": {
    "content": "Content to save as revision",
    "version": 3,
    "note": "Backup before major rewrite"
  }
}
```

*   **Response**: `201 Created`

