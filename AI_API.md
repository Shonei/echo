# AI API Documentation

The AI API provides a set of endpoints for interacting with AI (backed by Gemini) through managed, stateful conversation sessions.

All endpoints are located under the `/api/v1/ai` path and require authentication provided by the `api_auth` pipeline (typically a valid Bearer token).

## Base URL
`/api/v1/ai`

---

## Endpoints

### 1. Create a Conversation

Starts a new stateful AI conversation.

**Endpoint:** `POST /conversation`

**Request Body (JSON):**
```json
{
  "system_prompt": "You are a helpful assistant.", // optional
  "temperature": 0.7,                            // optional, default is 0.7
  "max_output_tokens": 1024,                     // optional
  "thinking_enabled": false,                     // optional, default is false
  "thinking_budget": 512,                        // optional
  "tools": []                                    // optional, list of tool definition maps
}
```

**Response (`201 Created`):**
Returns the generated conversation ID.
```json
{
  "id": "1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p"
}
```

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
Returns the newly generated conversation parts from the AI.
```json
{
  "parts": [
    {
      "text": "I am doing well, thank you for asking! How can I help you today?"
    }
  ]
}
```

**Errors:**
- `400 Bad Request`: Missing/invalid message text, or a downstream API error.
- `404 Not Found`: Conversation ID not found in memory.

---

### 3. Send Content Blocks

Sends a complex, multi-part message to the conversation. This is useful for sending tool call responses, images, or structured message parts that Gemini expects.

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
Returns the newly generated parts from the AI.
```json
{
  "parts": [
    {
      "text": "The capital of France is Paris."
    }
  ]
}
```

**Errors:**
- `400 Bad Request`: Missing/invalid content blocks list, or a downstream API error.
- `404 Not Found`: Conversation ID not found.

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

Kills a conversation and removes it from the server's memory.

**Endpoint:** `DELETE /conversation/:id`

**Path Parameters:**
- `id`: The conversation ID.

**Response (`204 No Content`):**
Empty response body on successful deletion.

---

## Function Calls (Tools)

Gemini allows the AI to call defined tools. You can provide these tool definitions when creating a conversation (`POST /conversation`).

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
