# Skills API Documentation

A **skill** is a preset that lives in a row rather than in compiled code:
markdown instructions, the tool names it is allowed to use, and generation
config. Running one starts an ordinary AI conversation, so everything a run does
is readable at `/ai-messages` like any other conversation.

See `designs/skills.md` for the design and the phases still to come. This
documents Phase 1.

## Authentication

Send `Authorization: Bearer <accessToken>` from `POST /api/v1/login` on every
request. **Every** skills endpoint requires it — nothing here is public, because
a run spends model credit and instructions are internal configuration.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/skills` | List skills. `?enabled=true\|false` filters. |
| `POST` | `/api/v1/skills` | Create a skill. |
| `GET` | `/api/v1/skills/:id` | Fetch by id **or slug**. |
| `PUT` | `/api/v1/skills/:id` | Update metadata. |
| `DELETE` | `/api/v1/skills/:id` | Delete, with its runs and variables. |
| `PUT` | `/api/v1/skills/:id/instructions` | Replace the markdown body. |
| `POST` | `/api/v1/skills/:id/run` | Queue a run. Returns `202`. |
| `GET` | `/api/v1/skills/:id/runs` | List runs, newest first. `?limit=` (max 200). |
| `GET` | `/api/v1/skills/:id/runs/:run_id` | Fetch one run. |
| `GET` | `/api/v1/skills/:id/variables` | List declared variables. |
| `PUT` | `/api/v1/skills/:id/variables` | Replace the whole declaration set. |
| `PUT` | `/api/v1/skills/:id/variables/:name` | Bind a `config` variable. |

Anywhere `:id` appears it accepts an id or a slug, so
`POST /api/v1/skills/weekly-report/run` works.

## Creating a skill

```http
POST /api/v1/skills
{"skill": {
  "slug": "weekly-dependency-report",
  "name": "Weekly dependency report",
  "description": "Checks dependencies for new releases.",
  "instructions": "Fetch the latest release for each dependency below...",
  "tools": ["http_request"],
  "provider": "openrouter",
  "model": "openai/gpt-5.6-luna",
  "temperature": 0.2
}}
```

Two fields behave differently from the rest.

**`provider` can only ever be set at creation.** A `provider` key on `PUT` is
*ignored*, not rejected — the same way `content` is on `PUT /blogs/:id`. This is
not fussiness: `google_search` and `openrouter:web_search` are different
services rather than two spellings of one capability, so moving a skill between
providers would silently drop or substitute part of what it was approved to do.
To change it, create a new skill. `null` means Gemini.

**`instructions` has its own route.** `PUT /api/v1/skills/:id` ignores an
`instructions` key; use `PUT /api/v1/skills/:id/instructions`. Editing the body
is a distinct operation from renaming the skill, which is what will make
revisions cheap to add later.

**`tools` holds names, not declarations**, and is validated on write: a name
that is not a registered Echo tool, or a built-in the skill's provider does not
offer, is rejected rather than stored and quietly ignored at run time. The
declarations are rendered for the provider when a run starts.

| Provider | Available names |
|---|---|
| Gemini (default) | `http_request`, `google_search`, `url_context` |
| OpenRouter | `http_request`, `openrouter:web_search`, `openrouter:web_fetch` |

## Variables

A skill declares the values it needs; an operator says what fills them. Those
are deliberately different privileges, and they are different endpoints.

```http
PUT /api/v1/skills/weekly-report/variables
{"variables": [
  {"name": "repo_name", "kind": "config", "type": "string", "required": true,
   "description": "Which repository to report on"},
  {"name": "since", "kind": "input", "type": "string"}
]}
```

This **replaces the whole set**, so it is idempotent when a caller retries.
Bindings survive for any variable whose `name` is unchanged; one that disappears
takes its binding with it, and one whose `kind` changes has its binding cleared.
The response says what that cost:

```json
{"data": [...], "dropped_bindings": ["old_var"], "unbound": ["repo_name"]}
```

| Kind | Set by | Resolved from |
|---|---|---|
| `config` | operator, once | `PUT /variables/:name` |
| `input` | the caller, per run | the run's `input` object |

`secret` and `oauth` are in the design and are **rejected** for now: there is no
secret store yet (Phase 6), so such a variable could only ever be unbound.

Binding a `config` variable:

```http
PUT /api/v1/skills/weekly-report/variables/repo_name
{"variable": {"value": "echo-server"}}
```

The literal is checked against the declared `type`, so a `number` variable
cannot be bound to `"abc"`. Binding an `input` variable is a `422` rather than a
no-op — its value arrives per run.

### Using a variable

The model writes the placeholder `$.name` into a tool argument, and Echo
substitutes the real value **immediately before the tool runs**:

```json
{"url": "https://api.github.com/repos/$.repo_name/releases"}
{"headers": {"Authorization": "Bearer $.token"}}
```

Two properties matter, and Phase 6's secrets depend on both:

- **The placeholder is what gets persisted.** The arguments stored in
  `ai_messages` keep `$.repo_name`, so a value is never written to the database
  and never replayed into later model requests.
- **A whole-string placeholder keeps its type.** `"$.retries"` on a `number`
  variable reaches the tool as `3`; `"n=$.retries"` reaches it as `"n=3"`.

Write `$$.name` for a literal `$.name` — jq and JSONPath use the same syntax.
A conversation with no skill behind it (the plain agent chat) never substitutes
at all.

## Running a skill

```http
POST /api/v1/skills/weekly-report/run
{"input": {"since": "2026-08-01"}}
```

Returns **`202`** with the run, and never waits for the model:

```json
{"data": {"id": 42, "status": "queued", "session_id": null, ...}}
```

The `input` object becomes the run's first message, three ways:

| Input | First message |
|---|---|
| `{}` | a fixed "run this skill now" instruction |
| `{"message": "..."}` | that text, verbatim |
| anything else | the JSON in an `<input>` block, framed as material to act on rather than instructions to follow |

**Required variables are checked before the row is inserted**, so a skill
missing a value fails immediately with `422` and the names, rather than `202`
and a run you have to poll to discover was doomed:

```json
{"errors": {"variables": ["repo_name is required but unbound"]}}
```

`enabled` is deliberately not consulted here: a skill can be taken off its
schedule and still be run by hand.

### Run statuses

| Status | Meaning |
|---|---|
| `queued` | inserted; the task has not started a conversation yet |
| `running` | a conversation exists; `session_id` is set |
| `succeeded` | finished; `result` holds the model's text |
| `failed` | finished; `error` says why |
| `awaiting_approval` | reserved for Phase 2; unreachable today |

Once `session_id` is set, the conversation is readable at
`/ai-messages/:session_id` — and it, not the run row, is the actual record of
the work. The run row is a log and an index.

**A restart mid-run leaves a row in `running` or `queued`.** That is accepted
rather than solved: runs are supervised tasks with no job queue behind them, so
a deploy abandons an in-flight one. Nothing is lost but the status; the
conversation itself is durable. To find stranded rows:

```sql
select id, skill_id, session_id, status, inserted_at
from skill_runs
where status in ('queued','running') and inserted_at < now() - interval '1 hour';
```

## Errors

| Status | When |
|---|---|
| `400` | the request body is missing its wrapper key (`skill`, `variables`, `variable`, `instructions`) |
| `401` | no token, or an invalid one |
| `404` | no skill with that id or slug |
| `422` | changeset errors, an unbound required variable, or an `input` that is not an object |
| `503` | too many runs already in flight |
