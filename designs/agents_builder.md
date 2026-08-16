# Agents Builder

This is the design of a new feature that will allow us to build AI agents and tools supporting both server-side tools and client-side tools. 

## User Stories

* User comes to the UI.
* User can define a server-side tool to return a random number.
* User can define an agent that can use the server-side tool to return a random number.
* User adds a client-side tool to edit files.
* The user can use that agent to edit a file. The server executes the server-side tool, while the client executes the client-side tool.

## Technical Design

### Data Schema Definitions

To support agents and reusable tools, we will introduce the following records:

1. **`Agent`**
   - `id`: UUID
   - `name`: String
   - `description`: Text
   - `system_prompt`: Text
   - `model_version`: String (e.g., `gemini-3.7-flash`)
   - `created_at` / `updated_at`

2. **`Tool`**
   - `id`: UUID
   - `name`: String (Must conform to API constraints like `^[a-zA-Z0-9_-]+$`)
   - `description`: Text
   - `type`: Enum (`server`, `client`)
   - `parameters_schema`: Map (JSON Schema defining arguments)
   - `endpoint_url`: String (Required if `type` is `server`)
   - `http_method`: String (Required if `type` is `server`, e.g., `POST`, `GET`)
   - `created_at` / `updated_at`

3. **`AgentTool` (Join Table)**
   - `agent_id`: UUID
   - `tool_id`: UUID
   *This establishes a many-to-many relationship, allowing tool definitions to be reused across multiple agents.*

### Server-Side Tools 

A server-side tool is defined as an HTTP endpoint. 

**Execution Flow**:
1. When generating a response, the Gemini model decides to call a server-side tool, returning a `ToolCall` function with parameters.
2. The `ConversationManager` intercepts this, maps the tool name to its DB Configuration, and handles execution internally.
3. The server makes an HTTP request (e.g., via `Req`) to the configured `endpoint_url` using the LLM-provided arguments as the payload.
4. The response body from the target server is captured, converted into a `ToolResponse`, and appended to the history.
5. The `ConversationManager` resumes the generation loop with the model to synthesize the final message based on the tool's response.

### Client-Side Tools 

Client-side tools are agent tools intended to be executed natively by the browser or client environment. 

**Execution Flow**:
1. Gemini responds with a `ToolCall` function matched to a `client` tool.
2. The `ConversationManager` pauses execution and yields a specific response to the client (e.g., an SSE payload or websocket message containing a `client_tool_call` event with the tool name and arguments).
3. The client receives the event and performs the requested local operation (e.g., executing client-side file editing routines).
4. Upon completion, the client submits the resulting output back to the server (e.g., via `POST /api/conversations/:id/tool_responses`).
5. The server appends this tool response to the conversation history and resumes the generation loop.

### Agents

Agents are configured instances holding a specific behavior and capability set. Each agent has its own `system_prompt` and a linked list of tools. The system will primarily support Gemini models. When a conversation session is tethered to an agent, the system will inject the agent's prompt and tool specifications on every generation request.

## Phases

This describes how we will incrementally deliver the feature.

### Phase 1: Foundation (Data Layer)

Clean up the existing systems and establish a solid foundation:
1. Define the `Ecto.Schema` and create migrations for `agents`, `tools`, and `agent_tools`.
2. Implement backend Contexts (`Echo.Agents`, `Echo.Tools`) for managing data interactions.
3. Build the CRUD UI/API endpoints for users to define and store configurations for both agents and tools in the system.

### Phase 2: Engine Integration (Server-Side Tools)

Extend the ConversationManager capability so it can integrate the custom agent logic:
1. Update `ConversationManager` to inject `Tool` parameter schemas into the LLM payload when an interaction involves an `Agent`.
2. Introduce an HTTP execution layer to automatically perform the backend HTTP requests when the Gemini model returns a server-side tool call.
3. Implement basic error handling for timeouts or failing backend endpoints.

### Phase 3: Client Handshake (Client-Side Tools)

Add support to the ConversationManager to properly handle client-side execution boundaries.
1. Define the frontend/backend payload contract used when the generation stream yields a client action.
2. Update the frontend integration to capture these execution events, perform the client logic (e.g., user prompting or file interaction), and seamlessly submit the results back over the API to continue the model loop.
