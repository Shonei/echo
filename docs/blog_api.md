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
| `current_version` | Integer | Version number of the latest content |
| `content` | String | Content from the latest revision |

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

Returns a list of all blogs with their latest content.

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
      "current_version": 2,
      "revisions_count": 2,
      "created_at": "2026-01-13T10:00:00Z",
      "updated_at": "2026-01-13T11:00:00Z"
    }
  ]
}
```

### 2. Create Blog

Creates a new blog. Automatically creates the first revision (Version 1).

*   **URL**: `/blogs`
*   **Method**: `POST`
*   **Payload**:

```json
{
  "blog": {
    "title": "New Blog Post",
    "slug": "new-blog-post",
    "status": "draft",
    "content": "Initial draft content.",
    "note": "First draft"
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
    "current_version": 1,
    ...
  }
}
```

### 4. Update Blog

Updates a blog.
*   If `content` is changed, a **new revision** is created automatically.
*   If only metadata (`title`, `status`, `slug`) is changed, no new revision is created.

*   **URL**: `/blogs/:id`
*   **Method**: `PUT`
*   **Payload**:

```json
{
  "blog": {
    "title": "Updated Title",
    "content": "This is new content.",
    "status": "public",
    "note": "Ready for publish"
  }
}
```

*   **Response**: `200 OK`

### 5. Delete Blog

Deletes a blog and all its associated revisions.

*   **URL**: `/blogs/:id`
*   **Method**: `DELETE`
*   **Response**: `204 No Content`

### 6. List Revisions

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
      "content": "This is new content.",
      "note": "Ready for publish",
      "created_at": "..."
    },
    {
      "id": 1,
      "version": 1,
      "content": "Initial draft content.",
      "note": "First draft",
      "created_at": "..."
    }
  ]
}
```

### 7. Get Revision

Get details of a specific revision.

*   **URL**: `/blogs/:id/revisions/:revision_id`
*   **Method**: `GET`
*   **Response**: `200 OK`
