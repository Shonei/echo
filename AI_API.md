# AI API Documentation

The AI API provides a set of endpoints for interacting with AI through managed, stateful conversation sessions.

A conversation runs on a **provider** — `gemini` (the default) or `openrouter`. The provider is fixed when the conversation is created. Whichever one answers, the request and response shapes documented here are identical: Echo translates to and from each backend's wire format internally.

Conversations are **durable**. Config and history are stored in Postgres, so a conversation survives a restart or a redeploy and is transparently resumed on the next request. There is no "expired from memory" state to handle — a conversation exists until you `DELETE` it.

All endpoints are located under the `/api/v1/ai` path and require authentication provided by the `api_auth` pipeline (a valid Bearer token from `POST /api/v1/login`).

## Base URL
`/api/v1/ai`

---

## Endpoints

### 1. Create a Conversation

Starts a new stateful AI conversation.

**Endpoint:** `POST /conversation`

**Request Body (JSON):** every field is optional.
```json
{
  "provider": "gemini",                          // "gemini" (default) or "openrouter"
  "model": "gemini-3.1-pro-preview",             // required for openrouter, see below
  "system_prompt": "You are a helpful assistant.",
  "temperature": 0.7,                            // default is 0.7
  "max_output_tokens": 1024,
  "thinking_enabled": false,                     // default is false; Gemini only
  "thinking_budget": 512,                        // Gemini only
  "response_modalities": ["TEXT"],               // Gemini only, e.g. ["TEXT", "IMAGE"]
  "tools": [],                                   // list of tool definition maps
  "variable_scope": null                         // see below; skills set this
}
```

`model` defaults to `GEMINI_MODEL` on Gemini. **OpenRouter has no default** — it fronts hundreds of models, so an `openrouter` conversation must name one (e.g. `"openai/gpt-5.6-luna"`) or every message will fail with `missing_model`.

`thinking_enabled`, `thinking_budget`, and `response_modalities` are not mapped for OpenRouter; setting them is logged and ignored rather than silently honoured.

`variable_scope` names where this conversation's `$.name` placeholders resolve from, as an opaque token. `Echo.Skills` sets it when it runs a skill (`"skill_run:42"`); ordinary callers leave it out, and then a `$.` in a tool argument is passed through as literal text — which is what keeps jq paths working. See `docs/skills_api.md`.

**Response (`201 Created`):**
Returns the generated conversation ID.
```json
{
  "id": "1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p"
}
```

**Errors:**
- `500 Internal Server Error`: the conversation could not be started — an unknown `provider`, or a database failure. Body is `{"error": "...", "details": "..."}`.

---

### 2. Send a Text Message

Sends a simple text string to an existing conversation and retrieves the AI's response. The conversation state is automatically updated to include both the user's message and the AI's response.

**Endpoint:** `PUT /conversation/:id/message`

**Path Parameters:**
- `id`: The conversation ID returned from the creation endpoint.

**Request Body (JSON):**
Expects one of the following fields for the text: `message`, `text`, or `content`.
```json
{
  "message": "Hello, how are you today?"
}
```

**Response (`200 OK`):**
Returns the newly generated conversation parts from the AI, plus provider metadata.
```json
{
  "parts": [
    {
      "text": "I am doing well, thank you for asking! How can I help you today?"
    }
  ],
  "metadata": {}
}
```

`metadata` is provider-specific and passed through verbatim — Gemini's `groundingMetadata` and `urlContextMetadata`, OpenRouter's `annotations`, `reasoning`, and `usage`. It is `{}` when the provider returned none, and is persisted alongside the reply, so whatever a server-side tool surfaced there stays in the audit trail. Treat it as opaque: read the keys you know and ignore the rest.

**Errors:** the body is `{"error": "..."}`.
- `400 Bad Request`: Missing/invalid message text, or a downstream API error.
- `404 Not Found`: No conversation exists with this ID — it was never created, or it was deleted. Note that a conversation whose process is not currently running is *not* a 404: it is resumed from Postgres transparently.

---

### 3. Send Content Blocks

Sends a complex, multi-part message to the conversation. This is useful for sending tool call responses, images, or structured message parts.

**Endpoint:** `PUT /conversation/:id/content`

**Path Parameters:**
- `id`: The conversation ID.

**Request Body (JSON):**
Expects one of the following fields containing an array of parts: `content_blocks`, `content`, or `blocks`.
```json
{
  "content_blocks": [
    {
      "text": "What is the capital of France?"
    }
  ]
}
```

**Response (`200 OK`):**
Returns the newly generated parts from the AI, plus provider metadata, exactly as endpoint 2 does.
```json
{
  "parts": [
    {
      "text": "The capital of France is Paris."
    }
  ],
  "metadata": {}
}
```

**Errors:** the body is `{"error": "..."}`.
- `400 Bad Request`: Missing/invalid content blocks list, or a downstream API error.
- `404 Not Found`: No conversation exists with this ID (see endpoint 2).

---

### 4. Create an Editor Assistant Conversation

Creates a pre-configured AI conversation specifically tailored for editing blog posts.
The conversation comes pre-loaded with a system prompt that grounds the AI as a Markdown blog editor, a low temperature (0.1) to keep edits faithful to the author's text, two document-editing tools (`edit_text`, `insert_lines`), and the `google_search` + `url_context` built-ins for checking a claim or a link when the author asks.

Prompt, tools, and settings live together in `Echo.Agents.Presets.editor/0`.

**Endpoint:** `POST /agents/editor`

**Request Body:**
None required.

**Response (`201 Created`):**
Returns the generated conversation ID to be used in subsequent `PUT` message requests.
```json
{
  "id": "1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p"
}
```

**Client contract.** The system prompt is written against how the Shonei Blogs editor drives this preset — changing one side means changing the other:

- The current post arrives as the **first content block of the first turn**, line-numbered with a `  12→text` gutter (`numberLines` in the client's `src/lib/edits.ts`). The prompt tells the model the gutter is for reference and is not part of the document.
- `edit_text` yields `{"replacements": [{"old_text", "new_text"}]}`. Each `old_text` must reproduce the document exactly, gutter excluded; the client replaces the first literal occurrence.
- `insert_lines` yields `{"line_number", "lines"}`, where `line_number` is the gutter number the first inserted line should take.
- The client applies tool calls to its preview pane as accept/reject diffs and does **not** send a `functionResponse` back, so the model should treat a tool call as the end of its turn.
- The post is sent once per conversation, so the model's copy goes stale as the author keeps typing. The prompt tells it to ask for the current wording when `old_text` no longer matches rather than guessing.
- The post and any fetched page are framed as material, never as instructions — relevant because `url_context` and `google_search` pull untrusted text into the same channel as the author's requests.

---

### 5. Create a Photographer Assistant Conversation

Creates a conversation tailored to visual direction for a post: it brainstorms scenes, style, and palette with the author before generating anything. Runs on `gemini-3-pro-image-preview` with `response_modalities` of `["TEXT", "IMAGE"]`, so responses may include `inlineData` image parts alongside text. Temperature is 0.7. Defined in `Echo.Agents.Presets.photographer/0`.

Like the editor, it expects the current post as the first content block of the first turn.

**Endpoint:** `POST /agents/photographer`

**Request Body:**
None required.

**Response (`201 Created`):**
```json
{
  "id": "1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p"
}
```

---

### 6. Delete a Conversation

Ends a conversation: stops its process and deletes its durable record, so it can no longer be resumed. Deleting the record is what makes this stick — without it, the next message to that ID would transparently rehydrate the conversation from Postgres.

Message history in `ai_messages` is deliberately **retained** and stays readable in the UI. Only the ability to continue the conversation is removed.

Deleting an ID that does not exist is not an error.

**Endpoint:** `DELETE /conversation/:id`

**Path Parameters:**
- `id`: The conversation ID.

**Response (`204 No Content`):**
Empty response body.

---

## Function Calls (Tools)

The model can call defined tools. You provide these tool definitions when creating a conversation (`POST /conversation`).

Three kinds of tool can be mixed in the same `tools` list:

- **Provider built-ins** — the backend runs these itself, with no round-trip to you, and reports what it did in the response's `metadata`. On Gemini: `{"google_search": {}}` and `{"url_context": {}}`, reported as `groundingMetadata` / `urlContextMetadata`. On OpenRouter: `{"type": "openrouter:web_search"}` and `{"type": "openrouter:web_fetch"}`, reported as `annotations`.
- **Echo tools** — declarations from `Echo.Agents.Tools`, currently `http_request`. Echo executes the call itself, feeds the result back to the model, and repeats up to 5 times per message before replying, so a single request can return several `functionCall` parts followed by the final text. Execution is limited to the tools the conversation declared. Selectable from the agent-chat UI; see `agents.md` for the SSRF guardrails on `http_request`.
- **Your own tools** — anything else you declare. Echo passes the `functionCall` back to you untouched and expects the result via `PUT /conversation/:id/content`, as described below.

**Declaration dialect differs by provider.** Gemini nests declarations under `functionDeclarations` with upper-cased JSON Schema types (`"OBJECT"`, `"STRING"`); OpenRouter takes a flat list of `{"type": "function", "function": {...}}` entries with standard lowercase types. Declare tools in the dialect of the provider you chose — the example below is Gemini's.

**Example Tool Definition in `POST /conversation`:**
```json
{
  "tools": [
    {
      "functionDeclarations": [
        {
          "name": "get_weather",
          "description": "Get the current weather in a given location",
          "parameters": {
            "type": "OBJECT",
            "properties": {
              "location": {
                "type": "STRING",
                "description": "The city and state, e.g. San Francisco, CA"
              }
            },
            "required": ["location"]
          }
        }
      ]
    }
  ]
}
```

When the AI decides to call a function, the API will return a `functionCall` part instead of text:

**AI Function Call Response from message/content endpoint:**
```json
{
  "parts": [
    {
      "functionCall": {
        "name": "get_weather",
        "args": {
          "location": "San Francisco, CA"
        }
      }
    }
  ]
}
```

You must execute the function locally and send the JSON result back to the AI using the `PUT /conversation/:id/content` endpoint:

**Providing the Function Response using `PUT /conversation/:id/content`:**
```json
{
  "content_blocks": [
    {
      "functionResponse": {
        "name": "get_weather",
        "response": {
          "temperature": 72,
          "unit": "F"
        }
      }
    }
  ]
}
```

**On OpenRouter, echo back the call's `id`.** OpenRouter pairs a result with its call by id rather than by name, so a `functionCall` from an OpenRouter conversation carries one:

```json
{ "functionCall": { "id": "call_abc123", "name": "get_weather", "args": { "location": "San Francisco, CA" } } }
```

Copy that `id` onto the `functionResponse` alongside `name`. If you omit it, Echo falls back to sending the name as the `tool_call_id` — which works for a single call but will mispair when the model emits several in one turn. Gemini has no such id and ignores the field.
