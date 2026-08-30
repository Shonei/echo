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
  "tool_config": {"http_request": {"gate": "mutations"}},
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

**`tool_config` says what the skill may invoke, and how.** It is keyed by tool
name — never by declaration; those are rendered for the provider when a run
starts. A name that is not a registered Echo tool, or a built-in this provider
does not offer, is rejected on write rather than stored and quietly ignored at
run time.

| Provider | Available names |
|---|---|
| Gemini (default) | `http_request`, `google_search`, `url_context` |
| OpenRouter | `http_request`, `openrouter:web_search`, `openrouter:web_fetch` |

Each tool's settings are an object, and every key is optional:

```json
{"http_request": {"gate": "mutations", "config": {}}}
{"http_request": {}}
```

**`gate`** decides when a call stops for a human instead of running:

| Gate | Stops |
|---|---|
| `never` *(default)* | nothing; the tool runs unattended |
| `mutations` | only calls the tool classifies as changing something. For `http_request` that is any method other than GET or HEAD |
| `always` | every call |

The tool classifies; the skill decides what to do about it. That split is what
keeps this configuration rather than a policy engine, and it is why a scheduled
skill that must write unattended can simply leave the gate at `never`.

An unknown gate is rejected on write — resolving it at run time would mean
guessing, and the safe guess is "stop", which would silently park every call the
skill makes.

**A gated call parks the whole turn**, siblings included: answering some of a
turn's calls and not others is a shape OpenRouter rejects outright, and it would
fire one call's side effect while waiting on a decision about its neighbour. The
run moves to `awaiting_approval` and its task ends. Resuming it — `/pending`,
approving, denying — arrives in Phase 2; until then a parked run is readable at
`/ai-messages` but cannot be continued.

## Variables

A skill declares the values it needs; an operator gives them their values. Those
are deliberately different privileges, and they are different endpoints.

**Variables belong to the skill, not to a run.** One value, shared by every run
of that skill. There is no per-run override — a run's own text reaches the
transcript a different way, described below.

```http
PUT /api/v1/skills/weekly-report/variables
{"variables": [
  {"name": "repo_name", "kind": "config", "type": "string", "required": true,
   "description": "Which repository to report on"},
  {"name": "github_token", "kind": "secret", "required": true,
   "description": "A token with repo scope"}
]}
```

This **replaces the whole set**, so it is idempotent when a caller retries.
Values survive for any variable whose `name` is unchanged; one that disappears
takes its value with it. The response says what that cost:

```json
{"data": [...], "dropped_bindings": ["old_var"], "unbound": ["repo_name"]}
```

| Kind | Reaches the model? | Rendered by the API? |
|---|---|---|
| `config` | in tool results, like anything else | yes |
| `secret` | never — replaced by its placeholder on the way back | never; only `bound: true` |

Redeclaring a `secret` as a `config` clears its value. That path is reachable by
the builder agent in Phase 3, and without it an agent could expose a stored
secret by rewriting its kind. Going the other way keeps the value, since that
only adds protection.

Giving a variable its value:

```http
PUT /api/v1/skills/weekly-report/variables/repo_name
{"variable": {"value": "echo-server"}}
```

The literal is checked against the declared `type`, so a `number` variable
cannot be given `"abc"`.

> **Secrets are stored in plain text for now.** Encrypting `skill_variables.value`
> is a later change, and a contained one: only `Echo.Skills.Variables` reads that
> column, and the API already never renders it.

### Using a variable

The model writes the placeholder `$.name` into a **tool argument**, and Echo
substitutes the real value immediately before the tool runs:

```json
{"url": "https://api.github.com/repos/$.repo_name/releases"}
{"headers": {"Authorization": "Bearer $.github_token"}}
```

Three properties matter:

- **The placeholder is what gets persisted.** The arguments stored in
  `ai_messages` keep `$.repo_name`, so a value is never written to the database
  and never replayed into later model requests.
- **A whole-string placeholder keeps its type.** `"$.retries"` on a `number`
  variable reaches the tool as `3`; `"n=$.retries"` reaches it as `"n=3"`.
- **A secret is scrubbed out of the tool's result** before it is persisted or
  shown to the model. A backstop, not a guarantee: a value the tool transforms
  — encoded, hashed, truncated — will not match and will not be caught.

**A `config` placeholder is filled in everywhere; a `secret` only inside a
tool.** A body reading `"Briefing for $.city"` reaches the model as
`"Briefing for London"`, and the variables block below it lists the value too —
so the model can put it in prose, or in a search query, without ever having to
resolve it itself.

A secret is different: `"Authenticate with $.api_key"` reaches the model with
the placeholder intact, and the value is substituted only into the arguments of
a tool Echo runs. The system prompt is stored once and replayed into every
subsequent request, so a secret expanded there would be re-sent for the life of
the conversation.

**Placeholders only resolve in tools Echo runs itself.** A provider's own search
or page fetch is invoked by the provider, so Echo never sees its arguments and
cannot substitute anything into them. That is another reason config values are
shown: the model has to pass the real value to those.

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

### Where a run's input goes

The `input` object is this run's own ad-hoc text, and it is **not** a variable.
It reaches the transcript two ways.

**Into the instructions, by placeholder.** Any `$.name` in the skill body is
filled from `input[name]` when the run starts:

```
skill body:  "Review the repo. $.instructions"
input:       {"instructions": "focus on the auth changes"}
prompt:      "Review the repo. focus on the auth changes"
```

Same sigil as a variable, deliberately — but two different sources resolved at
two different moments. A run's input is substituted into the **prompt**; a
skill's variables are substituted into **tool arguments**. The two namespaces
are kept disjoint: an input key that collides with a declared variable name is
ignored, so the run payload cannot write over a variable's placeholder.

**As the first message, for whatever is left.** Keys the prompt did not consume
become the opening user message:

| Remaining input | First message |
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
| `awaiting_approval` | a call is gated and waiting on a human. Reachable, but not yet resumable — see Phase 2 |

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

## Authoring a skill with an agent

`POST /api/v1/ai/agents/skill_builder` starts a conversation with an agent that
writes skills by talking to you, using the same message and content endpoints as
any other conversation. In the browser, the **Build one with the agent** button
on `/skills` does the same thing and drops you into the agent chat.

It can create and rename skills, write their instructions, declare their
variables, and search what already exists so it does not duplicate one. It also
carries Gemini's own search and page-fetch, so it can check an API's real shape
before writing instructions that depend on it.

**It can run a skill and wait for the result**, which is what makes authoring a
loop rather than a guess: write it, run it, read what came back, fix it. A run
started this way is an ordinary run — it does real work with whatever tools you
granted, and shows up in the skill's run list like any other. The wait is capped
at 90 seconds; past that the agent is told to check back with `get_skill_run`.

**It is told which tools a skill could be granted, and given none of them.** The
catalogue is rendered into its system prompt from the registry, so it cannot
name a tool that does not exist or miss one that was added, and it can advise on
a provider knowing that the choice is permanent and changes what is available.
Granting it those tools would be worse than useless: it would do the work in the
chat rather than write a skill that does it.

It deliberately cannot:

- **grant a skill its tools.** `tool_config` is not a field any of its tools
  accept. A grant is what a skill can reach out and do, so it is yours to make —
  tick the tools on the skill's page.
- **give a variable a value.** It declares that a skill needs a GitHub token; it
  has no way to say which one, and is never shown one.

Both are withheld rather than reviewed, which is a stronger property than
approving each change. It also means a skill can never be granted a
skill-writing tool: those are excluded from what any skill may declare, so a
skill cannot rewrite its own grants.

## Errors

| Status | When |
|---|---|
| `400` | the request body is missing its wrapper key (`skill`, `variables`, `variable`, `instructions`) |
| `401` | no token, or an invalid one |
| `404` | no skill with that id or slug |
| `422` | changeset errors, an unbound required variable, or an `input` that is not an object |
| `503` | too many runs already in flight |
