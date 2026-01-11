# AI Chat Feature

This document describes the AI chat feature that has been implemented in the Echo chat application.

## Overview

The AI chat feature allows users to mention AI users by their username (e.g., `@ai_bot`) in their chat messages to get responses from various AI models. When a message contains `@{ai_username}`, the system:

1. Detects AI user mentions in the chat message using the AI User Registry
2. Fetches the last 5 messages from the chat room (including the current one)
3. Sends the chat history to each mentioned AI user's configured model for processing
4. Posts the AI responses back to the chat room as messages from the respective AI users

## Architecture

### Components

1. **AIChatServer** (`lib/echo/ai_chat_server.ex`)
   - GenServer that handles AI interactions
   - Processes AI mentions asynchronously
   - Integrates with Google Gemini API
   - Creates and broadcasts AI responses

2. **ChatChannel** (`lib/echo_web/channels/chat_channel.ex`)
   - Modified to detect `@AI` mentions
   - Sends AI mention requests to AIChatServer

3. **ChatController** (`lib/echo_web/controllers/chat/chat_controller.ex`)
   - Also modified to detect `@AI` mentions in REST API calls
   - Ensures AI functionality works for both WebSocket and HTTP clients

### System Prompt

The AI uses the following system prompt:

```
You are an AI assistant participating in a chat room. You have been mentioned with @AI in a message.

Here is the recent chat history. Please respond helpfully and conversationally to the question or comment directed at you.
Keep your responses concise and friendly, as this is a casual chat environment.
```

## Configuration



## Usage

1. Join a chat room
2. Send a message that includes `@AI` anywhere in the text
3. The AI will respond with a message from "AI Assistant"

### Examples

```
User: @AI what's the weather like?
AI Assistant: I don't have access to real-time weather data, but I'd be happy to help you with other questions! You might want to check a weather app or website for current conditions.

User: Hey @AI, can you explain what Phoenix LiveView is?
AI Assistant: Phoenix LiveView is a library that enables rich, interactive web applications in Elixir without writing JavaScript. It uses WebSockets to maintain a persistent connection between the client and server, allowing for real-time updates and interactive features while keeping the application logic on the server side.
```

## Technical Details

### API Integration

- Uses Google Gemini Flash 2.5 model (`gemini-2.0-flash-exp`)
- API endpoint: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent`
- Configured with temperature: 0.7 and max output tokens: 500

### Error Handling

- If the API key is not configured, an error is logged
- If the Gemini API returns an error, a friendly error message is sent to chat
- Network timeouts are handled gracefully (30-second timeout)
- All errors are logged for debugging

### Message Flow

1. User sends message with `@AI`
2. Message is saved to database and broadcast to chat
3. `AIChatServer.process_ai_mention/2` is called asynchronously
4. Last 5 messages are fetched from the database
5. Messages are formatted and sent to Gemini API
6. AI response is received and processed
7. AI response is saved as a new message from "AI Assistant"
8. AI message is broadcast to all chat participants



## Limitations

- AI responses are limited to 500 tokens
- Only the last 5 messages are sent as context
- No conversation memory beyond the current chat session
- Rate limits apply based on your Gemini API quota

## Future Enhancements

Potential improvements that could be added:

- Configurable context window (more than 5 messages)
- Different AI models or providers
- User-specific AI preferences
- AI response formatting (markdown support)
- Conversation memory across sessions
- Rate limiting per user
- AI response caching for similar questions
