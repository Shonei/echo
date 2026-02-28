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
The conversation comes pre-loaded with a system prompt that grounds the AI as an expert blog editor with a low temperature (0.1) to avoid hallucinations. It also has access to the `edit_text` tool, which can apply an array of precise text replacements to a blog post.

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

---

### 5. Delete a Conversation

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
