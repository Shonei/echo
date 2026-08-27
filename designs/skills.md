# Skills: repeatable agent work, authored by an agent

> **Status: proposed.** Nothing here is built. Supersedes the earlier
> `designs/agents_builder.md`, which proposed DB-defined agents with
> HTTP-endpoint tools, was never implemented, and has since been deleted — the
> pieces of it worth keeping are folded in below.

## Context

Echo can hold a conversation with a model that calls tools, and that
conversation now survives a restart. What it cannot do is package a piece of
work so it can be run again later, by something other than a person typing.

`Echo.Agents.Presets` is the closest thing already in the tree: a named system
prompt bundled with its tools and generation settings, exposed at
`POST /api/v1/ai/agents/:name`. But a preset is a module attribute compiled
into the binary (`lib/echo/agents/presets.ex:15`, `:169`), so adding one is a
code change and a deploy, and only Echo's own developers can write one.

A **skill** is a preset that lives in a row: markdown instructions, a list of
tools it is allowed to use, and generation config. It is authored by talking to
a builder agent rather than by editing Elixir, test-run under supervision while
the author approves anything dangerous, and later fired by a trigger.

**Decisions:**

1. **Approval is per-tool configuration, not a runtime policy engine.** A tool
   can be marked as one that stops rather than runs; the call comes back for a
   human decision, exactly as a client-side tool does today. There is no
   approval mode, no policy evaluation, and nothing to catch — the model is
   only ever offered the tools the skill declared. A finished skill may keep
   gated tools: a parked run is an ordinary conversation and is resumable in
   the UI. See [The approval gate](#the-approval-gate).
2. **The tool list is a column, and only an operator writes it.** The markdown
   body carries instructions and may well name parameters for the agent to use —
   best-effort, and fine. What a skill may invoke is a security boundary, so it
   is never parsed out of prose an agent wrote. A skill file's `tools:` line is
   a grant an *operator* makes by importing it; no builder tool may import one.
   See [Costs](#costs-and-open-questions).
3. **The builder is an agent with server-side tools**, registered in the
   existing `Echo.Agents.Tools` backend registry (`lib/echo/agents/tools.ex:14`),
   so it inherits the tool loop, persistence, and the approval gate for free.
4. **Runs are Elixir tasks, and a task ends when the work does.** No job
   library, no retries, no queue. A run that parks on a gated call ends its
   task and gets a new one when it resumes, so a run is one task per stretch of
   unattended work rather than one task from start to finish. Deployment is
   single-replica, so there is no contention to design around. Durability is a
   deliberate trade, not an oversight: the point of this build is to find out
   whether the idea works at all, the host is stable, and releases are
   infrequent enough that abandoning the occasional in-flight run costs less
   than a job runner would.
5. **Approval resumes through the conversation resume that already exists.**
   A paused run needs no separate durable state: the model's `functionCall` is
   already in `ai_messages`, and `ConversationServer.init/1` rebuilds a
   conversation from Postgres (`lib/echo/agents/conversation_server.ex:79`).

## What a skill is

Three tables in Phase 1 — `skills`, `skill_runs`, `skill_variables` — and
everything else is the conversation machinery that already exists. The rest
arrive with the phase that needs them: `skill_code_blocks` in Phase 4,
`secrets` in Phase 6, `oauth_clients` and `oauth_connections` in Phase 7, and
`skill_triggers` in Phase 8, which is left unspecified until then.

The columns below that point at a later table are plain `uuid`s in Phase 1 and
gain their foreign key when that table exists, so Phase 1 migrates on its own.

```
skills
  id            uuid, primary key
  slug          string, unique      -- ^[a-z0-9-]+$, how a trigger names it
  name          string
  description   text                -- what it does, for listing and picking
  instructions  text                -- the markdown body: the actual SKILL.md
  tools         {:array, :string}   -- approved tool names (see below)
  provider      string              -- set at creation, never updatable.
                                    --  nil means Gemini, per Echo.Agents.Providers
  model         string              -- updatable, within that provider
  gated_tools   {:array, :string}   -- subset of tools that stop for a human
                                    --  instead of running. See the approval gate
  temperature   float
  max_output_tokens integer
  enabled       boolean             -- false stops triggers from firing it;
                                    --  a manual run still works, so a skill can
                                    --  be taken off its schedule and still tested
  timestamps
```

`tools` is a list of **names**, not declarations, because every tool a skill can
reach is defined somewhere else already:

| Kind | Named as | Declaration comes from |
|---|---|---|
| Echo tools | `http_request` | `Echo.Agents.Tools` → `tool_config/2` |
| Provider built-ins | `google_search`, `openrouter:web_search` | the provider's own shape |
| Pinned code blocks | the block's `name` | `skill_code_blocks.params_schema`, Phase 4 |

A skill has no client, which is what makes this sufficient.
`ai_conversations.tools` has to hold arbitrary declaration maps because Blogs
declares `edit_text` / `insert_lines` for *itself* to execute and Echo passes
them through untouched. A skill runs unattended: there is nobody on the other
end to run a client-side tool, so a skill never needs to store a declaration
it did not already have code for.

Starting a conversation from a skill therefore renders the tool list for the
skill's provider rather than copying it — the same `Tools.tool_config/2` call
`EchoWeb.AgentChatController` already makes (`lib/echo_web/controllers/agent_chat_controller.ex:239`).

Three things follow, and each of them is a bug avoided rather than a nicety:

- The file projection round-trips exactly, in both directions, because
  `tools: [http_request]` is the storage rather than a lossy rendering of it.
- Phase 5's tool intersection becomes a set operation on strings. Comparing
  nested declaration maps structurally is a privilege boundary implemented as
  deep equality, which is where subtle holes live.
- "Approve and remember" appends one string.

### Provider is fixed at creation

**A skill's provider can never change.** Note that storing names rather than
declarations is *not* what makes this necessary — rendering late would survive a
provider switch just fine, syntactically. The reason is capability parity.

Echo's own tools are portable: one canonical declaration, rendered into whatever
dialect the provider wants. Built-ins are not. `google_search` and
`openrouter:web_search` are not one capability under two spellings — they are
different services, reached differently, reporting differently
(`groundingMetadata` versus `annotations`). There is no honest mapping between
them, and a grant list that is portable in one half and not the other is worse
than one that is not portable at all: it would move a skill to a new provider
while silently dropping or substituting part of what it was approved to do.

So the lock is about what a skill may *do*, not about how its tools are spelled.
That reason holds whatever the column ends up storing.

This mirrors conversations, where the provider is fixed at creation and read
back from the record on every resume rather than from `opts`, for the same
reason: a provider that can drift is a provider that will
(`lib/echo/agents/providers.ex:5-8`). To change a skill's provider, create a
new skill.

`model` stays updatable — swapping models within one provider is routine and
changes nothing about tool syntax.

Immutability is enforced, not merely intended, through the same changeset split
the variables use (see [Two writers, one row](#two-writers-one-row)):

- **`create_changeset`** casts `provider` along with everything else.
- **`update_changeset`** does not cast `provider` at all, so no API shape, form
  field, or builder tool can reach it.

`Echo.Content.Blog` already does this to keep `content` out of metadata updates
(`lib/echo/content/blog.ex:52`), which is why `PUT /blogs/:id` can safely ignore
a `content` key rather than having to reject it.

A third path writes `tools` alone: "approve and remember" appends a tool to a
skill mid-run (see [The approval gate](#the-approval-gate)). It appends to that
one column and touches nothing else.

```
skill_runs
  id            uuid, primary key
  skill_id      references skills
  trigger_id    uuid, nullable      -- null for a manual run. Plain column in
                                    --  Phase 1; the FK to skill_triggers is
                                    --  added in Phase 8 when that table exists
  session_id    string              -- the ai_conversations / ai_messages id
  status        string              -- queued | running | awaiting_approval
                                    --  | succeeded | failed
  input         map                 -- trigger payload, or the user's instruction
  result        text                -- the final assistant text
  error         text
  started_at, finished_at
  timestamps
```

The run row is a log and an index, not a state machine anyone recovers from.
The conversation is where the actual work is recorded, and `session_id` is the
join to it.

```
skill_variables            -- declaration and binding, written by two paths
  id
  skill_id      references skills
  name          string   -- ^[a-z_][a-z0-9_]*$, referenced as $.name
  kind          string   -- secret | oauth | config | input
  type          string   -- string | number | boolean
  description   text     -- shown to the model and to whoever fills it in
  required      boolean
  position      integer  -- stable ordering for forms
  oauth_provider string  -- kind=oauth: which provider it wants, e.g. "github".
                         --  Named apart from skills.provider, which is a model
                         --  backend -- two unrelated meanings of one word

  -- Both are plain columns in Phase 1; the FKs and the tables they point at
  -- arrive with the phase that introduces them.
  secret_id     uuid     -- kind=secret. FK to secrets in Phase 6
  connection_id uuid     -- kind=oauth. FK to oauth_connections in Phase 7
  value         text     -- kind=config: the literal
  timestamps

secrets                    -- global, not per-skill. Phase 6.
  id
  name            string, unique   -- github_api_key
  description     text
  encrypted_value binary
  last_used_at    utc_datetime
  timestamps
```

`input` variables have neither column: their values arrive per run in
`skill_runs.input`.

See [Variables and secrets](#variables-and-secrets) for how these are resolved.

Instructions follow the blog convention of splitting content from metadata
(`lib/echo/content.ex:70`, `lib/echo/content/blog.ex:52`) so that editing a
skill's body is a distinct operation from renaming it — worth having when the
thing writing the body is a model. Revisions are not in scope for Phase 1 but
the split is what makes adding them later cheap.

### Rendering a skill as a file

A skill is exportable as one markdown file, frontmatter plus body, so it can be
read, diffed, and pasted between systems:

```markdown
---
name: weekly-dependency-report
description: Checks our dependencies for new releases and writes a summary.
tools: [http_request]
model: openai/gpt-5.6-luna
provider: openrouter
---

Fetch the latest release for each dependency listed below and summarise
anything that changed...
```

This is a **projection**, in both directions: importing a file writes the
columns. The columns remain authoritative at run time, so a hand-edited
`tools:` line in an exported file grants nothing until it has been imported and
saved.

Because `tools` stores names, the frontmatter can carry the same names the
column does and a skill round-trips through a file without loss. That is a
convenience of the format, **not** a relaxation of decision 2: the column is
still the only thing consulted at run time, and importing a file is an operator
granting those tools, exactly as if they had ticked them in a form. No builder
tool may import a skill file — an agent that could write frontmatter and then
import it would be writing its own grants, which is the precise thing decision 2
exists to prevent.

Import validates: a name that is not a registered Echo tool, a built-in the
skill's provider does not offer, or a pinned block that does not exist is
rejected rather than stored. `provider` is honoured on create and ignored on
update, per [Provider is fixed at creation](#provider-is-fixed-at-creation).

## Running a skill

A trigger creates a `queued` run, spawns a task, and returns the run id. It
never waits for the model. The existing message path blocks for up to 300s
(`lib/echo/agents/conversation_manager.ex:70`), which is fine for a person at a
keyboard and useless for a webhook.

```mermaid
sequenceDiagram
    participant T as Trigger
    participant R as Echo.Skills
    participant Task as Run task
    participant C as ConversationServer
    participant M as Model

    T->>R: run(skill, input)
    R->>R: insert skill_run (queued)
    R->>Task: start_child
    R-->>T: 202 {run_id}
    Task->>C: start_conversation(from skill)
    Task->>C: message(input)
    C->>M: generate
    M-->>C: reply / tool calls
    C-->>Task: parts
    Task->>R: update run (succeeded, result)
```

Starting the conversation is `ConversationManager.start_conversation/1`
(`lib/echo/agents/conversation_manager.ex:37`) with the skill's columns as
opts: `system_prompt` from `instructions`, plus `tools`, `provider`, `model`,
and the generation settings. The skill's markdown becomes the system prompt
verbatim.

Because runs are tasks with no supervision beyond the node, **a restart mid-run
leaves the row stuck in `running`.** That is accepted, not solved: the
conversation itself is durable and readable, so nothing is lost but the status.

## The approval gate

**A tool that needs a decision is a tool that stops instead of running.** That
is the whole mechanism, and Echo already has the path for it.

`Echo.Agents.Tools.executable_calls/2` returns only the calls whose name is in
the conversation's `backend_tools` (`lib/echo/agents/tools.ex:73`); every other
`functionCall` falls through untouched and comes back to the caller in `parts`.
That is exactly how the blog editor's `edit_text` works — Echo hands the call
back, and the caller answers with a `functionResponse` through
`PUT /conversation/:id/content`. A gated tool is a server tool borrowing the
client tool's path.

So there is no approval *mode*, no policy engine, and no second gate composed
with the declared set. There is one list.

**Gated tools.** A conversation carries which of its declared tools may not run
unattended, and `backend_tools` becomes declared-minus-gated:

```elixir
# today (lib/echo/agents/conversation_server.ex:107)
backend_tools: Echo.Agents.Tools.enabled(convo.tools)

# with gating
backend_tools: Echo.Agents.Tools.enabled(convo.tools) -- record.gated_tools
```

The model is only ever offered the tools the skill declared. It cannot ask for
something it was not given, so nothing has to be caught — a gated call simply
is not executed, the turn ends, and the process is free. `skills` carries
`gated_tools` alongside `tools`; `ai_conversations` gains the same column so a
resumed conversation rebuilds the gate from Postgres like everything else.

**Pausing needs no new durable state.** The model's `functionCall` is persisted
before the loop continues (`store_parts/5` at
`lib/echo/agents/conversation_server.ex:279`, called from `run_turn/5` before
`continue_turn/7`), so a pending call is already in `ai_messages`: it is a
`functionCall` in the last model turn with no answering `functionResponse`.
That is derivable from history and therefore still correct after a restart,
because `init/1` replays it (`:79`, `replay_into_turns/1` at `:304`).

On Gemini a `functionResponse` carries only `name`, so two parallel calls to the
same tool cannot be paired by name. Pair by position: parts are ordered, tool
responses are generated in call order, and rows come back ordered by `id`.
OpenRouter carries an `id` and pairs by that.

### Two shapes of resume

Approval looks like one action and is two, because the thing being approved is a
**server-side** tool whose result only Echo can produce.

| Gated tool | What a decision means | How it resumes |
|---|---|---|
| Server tool (`http_request`, `run_elixir`) | "yes, execute it" | Echo runs the pending call and continues |
| Deny, or a tool the operator answers | "here is the result" | an ordinary `functionResponse` |

Only the first needs an endpoint of its own, and it is thin — it re-reads the
pending call from history, runs it through `Echo.Agents.Tools.run/1`
(`lib/echo/agents/tools.ex:92`), and continues the loop exactly as
`continue_turn/7` would have:

```
GET  /api/v1/ai/conversation/:id/pending   -> calls awaiting a decision
POST /api/v1/ai/conversation/:id/approve   -> {call_id}
```

Deny is not an endpoint. It is a `functionResponse` saying the call was refused,
posted to the `/content` route that already exists. The model gets to react and
explain rather than the turn dying, and the refusal stays in the transcript.

**Approve and remember** is one column edit: drop the name from the skill's
`gated_tools`. Note what it is *not* — it never widens `tools`, because the model
could not have called something outside that list in the first place. A skill
gains a tool only when an operator or the builder agent adds one.

`remember` therefore has no meaning on a conversation with no skill behind it,
which the plain agent chat is. There it is simply unavailable.

### Waiting is a normal state, not a failure

A skill run whose turn ends on a gated call moves to `awaiting_approval` and its
task ends. Nothing holds a process open across human time.

That run is not stranded. It is an ordinary conversation with its own
`session_id`, readable and resumable in the UI like any other, so a finished
skill may absolutely carry gated tools — a nightly job that parks on its one
dangerous call and waits to be looked at is a reasonable thing to want, not a
misconfiguration.

**Partial answers: the backend allows them, the UI should not.** Posting one
`functionResponse` for two pending calls is accepted, and the loop resumes with
one still unanswered. Gemini pairs by name and position and will generally
tolerate that; OpenRouter pairs by `tool_call_id`, and an assistant message with
two `tool_calls` followed by one `tool` message is the shape OpenAI-compatible
endpoints reject. So completeness is the approval UI's job, and on OpenRouter it
is what keeps the turn valid rather than merely tidy.

## Variables and secrets

A skill declares the variables it needs, and the builder agent writes that
schema alongside the instructions. Three kinds:

| Kind | Set by | Resolved from | Example |
|---|---|---|---|
| `secret` | operator, once | the secret store | `$.github_api_key` |
| `config` | operator, once | the `value` column | `$.repo_name` |
| `input` | the trigger, per run | the run's `input` map | `$.issue_number` |

The agent references them by name in tool arguments — `$.github_api_key` — and
the placeholder is resolved **server-side, immediately before the tool runs**.

### Two writers, one row

The builder agent declares what a skill *needs*. Only an operator says what
actually fills it. Those are different privileges: a tool that could do both
could point a skill at any secret in the store, which is the same
privilege-escalation shape as a sub-agent granting itself its parent's tools.

So `skill_variables` is written through two changesets, following the split
already used for blogs (`lib/echo/content/blog.ex:52`, where content is only
writable via `Echo.Content.update_blog_content/2`):

- **`declaration_changeset`** casts `name`, `kind`, `type`, `description`,
  `required`, `position`. This is what the builder agent's tool reaches.
- **`binding_changeset`** casts `secret_id` and `value`, and is reachable only
  from the operator API and UI. No agent tool calls it.

An agent can therefore say *"this skill needs a GitHub token with repo scope"*
and cannot say *"and here is which one to use"*.

**Secrets are global, not per-skill**, because one `github_api_key` is
realistically shared by several skills and rotating it should be one edit
rather than a hunt. That also keeps encryption in a single table, and gives
`last_used_at` somewhere honest to live.

### Defining the schema

The builder agent gets one tool, `define_variables(skill, variables)`, which
replaces the whole declaration set rather than patching it. Declarative is
easier for a model to get right than a sequence of add/update/remove calls, and
it is idempotent when the agent retries.

Replacement keeps bindings for variables whose `name` survives unchanged, and
drops bindings for variables that disappear. The tool result says which
bindings were dropped and which new variables are unbound, so the agent can
tell the operator what still needs filling in — and a skill with unbound
required variables cannot run.

### The model never sees a secret's value

This is the property the whole design hangs on, and it has a specific reason.
Conversation history is persisted to `ai_messages` and replayed into *every*
subsequent model request (`replay_into_turns/1`,
`lib/echo/agents/conversation_server.ex:304`). A secret expanded into a tool
call would therefore be written to Postgres and re-sent to the provider on
every turn for the rest of the conversation. Expanding secrets into the system
prompt is worse for the same reason.

So substitution happens at the last possible moment and is not recorded:

```mermaid
flowchart LR
    M[Model emits call<br/>Bearer $.github_api_key] --> P[Persist to ai_messages<br/>placeholder intact]
    P --> R[Resolve $.github_api_key]
    R --> T[Execute tool with<br/>the real value]
    T --> S[Scrub known values<br/>from the result]
    S --> P2[Persist result,<br/>feed back to model]
```

The arguments stored in `ai_messages` keep the placeholder. Only the in-memory
map handed to `Echo.Agents.Tools.run/1` carries the real value, and it is never
written back.

**Results are scrubbed on the way in.** A tool can echo a secret back without
meaning to — an error message quoting the failing URL, a redirect target, a
response body reflecting a header. Before a `functionResponse` is persisted or
shown to the model, the resolved values used in that call are replaced with
their placeholders. This is a backstop, not a guarantee: a secret the tool
transforms — base64-encoded, hashed, embedded in a longer token — will not
match and will not be caught.

### Declaring, validating, failing early

The variable names, kinds, and descriptions are injected into the system prompt
so the agent knows what exists; values never are. A call referencing an
undeclared name comes back as an error result the model can react to, in the
same style as the other tool failures.

Required variables are checked **before the first model call**, when a run
starts. A skill missing its API key should fail immediately with a clear
message, not burn a turn and then fail inside a tool.

The approval UI shows placeholders, exactly as the model wrote them, so
approving a call never displays a secret.

### Interaction with pinned code

Approved code blocks resolve variables in their arguments the same way, so a
block can hold a secret in a local binding. That is intentional — the code is
human-reviewed — but it means a block *can* return a secret, and scrubbing is
what stands between that and the transcript. Blocks that touch secrets deserve
a closer read at approval time than blocks that do not.

## OAuth2 clients and connections

Most integrations do not need this. A GitHub PAT, a Stripe key, a Linear API
key — all of those are just secrets, and Phase 6 covers them. OAuth2 is for
when a provider will not issue a long-lived key, or when Echo must act as an
account rather than as itself. It is a separate phase because it is a separate
subsystem, not a variety of secret.

It has three layers, and conflating them is the usual way this goes wrong:

| Layer | Who does it | How often | Produces |
|---|---|---|---|
| Register the app | operator, on the provider's site | once per provider | `client_id` + `client_secret` |
| Authorize a connection | operator, through a browser flow | once per account | access + refresh token |
| Use and refresh | Echo, at run time | every call | a valid bearer token |

Only the first is manual and out-of-band: someone opens GitHub's developer
settings, creates an OAuth app, pastes the redirect URI Echo shows them, and
brings back a client id and secret. Nothing automates that, and nothing should
pretend to.

```
oauth_clients              -- the registered app
  id
  provider          string, unique    -- github, google, notion
  display_name      string
  client_id         string
  client_secret     binary            -- encrypted
  authorize_url     string
  token_url         string
  default_scopes    {:array, :string}

  -- Provider quirks, as config rather than code. See the costs section.
  auth_style        string   -- basic | body: where client creds go
  scope_delimiter   string   -- " " for most, "," for GitHub
  uses_pkce         boolean
  timestamps

oauth_connections          -- one authorized account
  id
  oauth_client_id   references oauth_clients
  label             string   -- which account this is, for the UI
  access_token      binary   -- encrypted
  refresh_token     binary   -- encrypted, null when the provider issues none
  expires_at        utc_datetime, nullable   -- null means it does not expire
  scopes            {:array, :string}
  status            string   -- active | needs_reauth | revoked
  last_refreshed_at utc_datetime
  timestamps
```

### It reuses the variable machinery

A connection is reached exactly like a secret: a skill declares a variable of
`kind: oauth` with the provider it wants, an operator binds it to a specific
connection, and `$.github` resolves at tool-execution time to a valid bearer
token that is never written to the transcript. All of
[Variables and secrets](#variables-and-secrets) applies unchanged — late
substitution, scrubbing on the way back, placeholders in `ai_messages`.

The write boundary holds too, and matters more here. The agent declares *"this
skill needs a GitHub connection with `repo` scope"*. It cannot choose which
account that is.

### How the agent knows an app exists

A read-only tool, `list_integrations`, returns for each provider: whether a
client is registered, which connections exist by label, and what scopes each
holds. No ids that grant anything, no tokens. This is a tool rather than
something injected into the system prompt because the answer changes between
runs and the builder should look it up when it becomes relevant.

It lets the builder say "there is already a GitHub app, and a connection
labelled `Shonei` with `repo` scope, so I will declare a variable for it"
instead of proposing that you go and create an app you already have.

### Connecting

```mermaid
sequenceDiagram
    participant U as Operator (browser)
    participant E as Echo
    participant P as Provider

    U->>E: GET /oauth/clients/:id/connect
    E->>E: sign state {client_id, nonce, exp}<br/>+ PKCE verifier if required
    E-->>U: 302 to provider authorize_url
    U->>P: consent
    P-->>U: 302 to /oauth/callback?code&state
    U->>E: GET /oauth/callback
    E->>E: verify state, recover client + verifier
    E->>P: POST token_url (code, client creds)
    P-->>E: access + refresh token
    E->>E: insert oauth_connection
    E-->>U: connected, showing the label
```

The redirect URI is **one fixed path**, `/oauth/callback`, because it has to be
registered with the provider ahead of time. Which client a callback belongs to
comes from the signed `state`, which also carries a nonce and an expiry so the
callback cannot be replayed or forged. PKCE verifiers ride alongside it for
providers that require them.

### Refreshing

On resolve, a connection whose `expires_at` is inside a small skew window is
refreshed before use. Two details matter more than the mechanics:

**Concurrent refresh must be serialized.** Two tool calls in one turn can
resolve the same connection at once, both refresh, and — with any provider that
rotates refresh tokens — the loser's token is already invalid, permanently
breaking the connection. Refresh therefore happens inside a transaction holding
`SELECT ... FOR UPDATE` on the connection row. A per-connection GenServer would
match the house style (`Echo.Agents.ConversationRegistry` does exactly that),
but the row lock is simpler and stays correct if a second replica ever exists.

**Refresh failure is terminal, not retryable.** A revoked grant or an expired
refresh token sets `status: needs_reauth` and fails the run with a message
naming the connection. It does not retry, and it does not fall through to an
unauthenticated call.

### The UIs

Three screens, all behind the existing browser basic auth:

- **Clients** — list, create, edit. Shows the redirect URI to paste into the
  provider, and never renders `client_secret` after it is saved.
- **Connections** — per client: labels, scopes, expiry, a `needs_reauth` badge,
  and connect / reconnect / disconnect. This is where a broken integration
  becomes visible, so it is the screen that matters when a 3am run fails.
- **Binding** — on the skill, the operator picks which connection fills each
  `kind: oauth` variable. The same screen binds secrets.

## Pinned code blocks

The goal is for the agent to write Elixir and have it run. The problem is that
the BEAM has no sandbox — process isolation is for failure, not security. Any
process can reach `File`, `System.cmd`, `Echo.Repo`, and `Application.get_env`,
where every API key lives. Three things have no in-VM defence at all:
`:erlang.halt/0` stops the node, `String.to_atom/1` in a loop permanently
degrades the VM by exhausting the atom table, and `System.cmd/3` shells out.
Filtering the AST for these is a losing game: `apply/3`, dynamic dispatch,
macros, and the whole `:erlang` module make the escape surface unbounded.

**So arbitrary code never runs at run time. Only reviewed code does.**

Approval already exists for exactly this shape of decision, so code reuses it:

```mermaid
flowchart LR
    A[Agent writes Elixir] --> B{Approval gate}
    B -- denied --> C[Refusal fed back<br/>as the tool result]
    B -- approved --> D[Execute, return result]
    D --> E[Pin to skill:<br/>name, params, code, hash]
    E --> F[Run time: exposed as<br/>a named, typed tool]
```

The two halves are deliberately different tools:

- **`run_elixir`** takes `code` and `args`. It is offered **only** while a
  conversation is in authoring mode, and always gated, so it is the ordinary
  two-part server tool from [The approval gate](#the-approval-gate): the call
  comes back with the code as its argument, a human reads it, and `/approve`
  makes Echo execute it. It is never in a running skill's tool set, so a running
  skill cannot express "execute this code" at all.
- **Each pinned block** is offered at run time as its own function declaration,
  with its own name, description, and parameter schema. The model calls
  `compute_totals(orders: [...])` — it supplies arguments, never code.

This is the `agents_builder.md` idea of user-defined tools, with Elixir in
place of configured HTTP endpoints, and with a human approval as the gate.

```
skill_code_blocks
  id
  skill_id      references skills
  name          string   -- ^[a-z_][a-z0-9_]*$, becomes the tool name
  description   text     -- shown to the model
  params_schema map      -- canonical JSON Schema, as Echo.Agents.Tools uses
  code          text
  code_hash     string   -- what was approved; execution requires a match
  approved_at   utc_datetime
  timestamps
```

Code is evaluated with the validated arguments bound to `args`, and the result
encoded into the `functionResponse`. Failures come back as a result the model
can read and react to, the way `Echo.Agents.Tools.HttpRequest` already returns
its errors rather than raising (`lib/echo/agents/tools/http_request.ex:73-85`).

Runaway code is the failure mode that *does* have in-VM answers, and both are
used: the block runs inside a task carrying
`Process.flag(:max_heap_size, %{size: _, kill: true})`, and the caller uses
`Task.yield/2` with a `Task.shutdown(task, :brutal_kill)` fallback. That covers
memory bombs and infinite loops. It does not cover `halt`, atom exhaustion, or
shelling out — those remain possible for any code a human approves, which is
the residual risk this design accepts rather than solves.

## Sub-agents

The value is context isolation. A skill that needs to read twenty pages to
answer one question should not carry all twenty into its own history — it hands
the job to a child, and gets back the answer instead of the transcript.

A sub-agent is an ordinary conversation, so it is persisted and readable at
`/ai-messages` like any other, with its own `session_id`. The parent's
`functionResponse` records only the child's final text; the working is kept but
kept out of the parent's context.

Three constraints, none of which the existing tool loop gives for free:

**A child may never hold a tool its parent lacks.** Otherwise `spawn_agent` is
a privilege-escalation primitive: a skill granted only `http_request` could
spawn a child granted `create_skill` and rewrite its own grants. The child's
tool set must be intersected with the parent's, server-side, never from an
argument the model supplies.

Intersect against the **skill's** `tools` — names, so it is a set operation on
strings — reached through the run row, which joins `session_id` to `skill_id`.
Not against `ai_conversations.tools`, which still holds provider-shaped
declaration maps for the sake of client-declared tools; comparing those
structurally would be a privilege boundary implemented as deep equality on
nested maps. A child also inherits the parent's `gated_tools`, or gating would
be escapable by delegation.

**Recursion needs its own ceiling.** `@max_tool_iterations` caps calls per turn
(`lib/echo/agents/conversation_server.ex:11`), not nesting depth — a child
spawning a child is a fresh conversation with a fresh counter. Depth must be
tracked on the conversation and capped, with `spawn_agent` removed from the
tool set at the last permitted level rather than erroring at it.

**The parent blocks while the child runs, and now has a budget to share.** A
turn carries one deadline (`@turn_budget_ms`, 270s) that every model call inside
it draws down, so the parent's remaining time is a real number rather than an
unbounded sum of per-call timeouts. A child must be given a slice of what is
left and must not be started when too little remains — otherwise the child
consumes the parent's budget and the parent returns having done nothing with it.

That is the whole of what Phase 5 has to decide here. The older and worse
problem — a turn whose inner budget could exceed the `GenServer.call` waiting on
it, so the caller got a 500 for work that had completed and was durable — is
fixed; the deadline is where the fix lives.

The remaining option, if a child ever needs more than a slice of one turn, is to
make sub-agent calls asynchronous: the parent parks and resumes exactly as the
approval gate does. That composes with everything here and stays a later choice
rather than a Phase 5 decision.

## Phases

**Phase 1 — Skills as data.** `skills`, `skill_runs`, and `skill_variables`
tables and contexts, CRUD API under `/api/v1/skills`, and
`POST /api/v1/skills/:slug/run` returning `202 {run_id}`. A `Task.Supervisor`
joins the supervision tree next to the conversation registry
(`lib/echo/application.ex:31`). Deliverable: a hand-written skill row can be
run, and its conversation read back at `/ai-messages`.

Variables are here rather than with secrets because a skill without parameters
is barely a skill, and because building substitution and scrubbing once —
against `config` and `input` variables, which are not sensitive — means the
security-critical plumbing is written and tested *before* there is anything
secret flowing through it. Phase 6 then adds the `secrets` table, the FK, and a
resolver backend behind the interface Phase 1 already calls.

**Phase 2 — Gated tools.** A `gated_tools` column on `ai_conversations` and
`skills`, subtracted from `backend_tools` in `ConversationServer.init/1`;
pending-call derivation; the `/pending` and `/approve` endpoints; and the UI
that shows a pending call and its arguments. Deny needs no new endpoint — it is
a `functionResponse` on the `/content` route that already exists.

Independent of skills: it applies to any conversation, including the existing
agent chat, which can already call `http_request`. `remember` is the one part
that is skill-only, since there is no `gated_tools` list to edit on a
conversation with no skill behind it.

**Phase 3 — Builder agent.** `create_skill`, `update_skill`,
`update_skill_instructions`, and `define_variables` as backends in
`Echo.Agents.Tools`, plus a `skill_builder` preset at
`POST /api/v1/ai/agents/skill_builder`. Ordered after Phase 2 deliberately: an
agent that can write skills is exactly the thing that should be gated from its
first day. None of these tools can bind a variable to a secret — see
[Two writers, one row](#two-writers-one-row).

**Phase 4 — Pinned code blocks.** An `run_elixir` tool available only while
authoring, whose approved code is pinned to the skill and re-exposed at run
time as named, typed tools. See [Pinned code blocks](#pinned-code-blocks).

**Phase 5 — The sub-agent tool.** A `spawn_agent` backend that starts a fresh
conversation with a caller-supplied prompt and tool subset, runs it to
completion, and returns its final text as the `functionResponse`. Pure Echo
machinery, no external dependency; it composes what Phases 1–3 already built.
Independent of Phase 4, so the two can swap freely.

See [Sub-agents](#sub-agents) for the constraints, which are not obvious.

**Phase 6 — Secrets and the first real tools.** Encrypted storage behind the
`secret_id` resolver Phase 1 already calls, a secrets admin UI, and the
integrations a plain API key unlocks — which is most of them. A skill that can
only make anonymous HTTP requests cannot do much, so capability comes before
automation.

One tool here is a prerequisite rather than a nicety: **something a skill can
report through** — mail, chat, or an outbound webhook. A scheduled skill with no
output channel produces nothing anyone sees, so Phases 8 and 9 deliver very
little without it.

**Phase 7 — OAuth2.** `oauth_clients` and `oauth_connections`, the connect and
callback flow, refresh with row-level locking, the `list_integrations` tool, and
the three admin screens. Deliberately after Phase 6 and separable from it: a
stored API key covers most providers, and this is only needed where one will not
be issued. See [OAuth2 clients and connections](#oauth2-clients-and-connections).

**Phase 8 — Triggers: manual and webhook.** The `skill_triggers` table, a
`create_trigger` builder tool, a UI button that takes an optional instruction,
and a webhook endpoint. The webhook reuses the `AcceptAny` + `CacheRawBody`
plugs from the existing echo sink so an HMAC can be computed over the exact
bytes received.

**Phase 9 — Cron triggers.** A self-scheduling GenServer in the house style of
`Echo.Requests.RequestCleanupJob`, which re-arms itself with
`Process.send_after/3` after each tick
(`lib/echo/requests/request_cleanup_job.ex:61-62`), ticking against a
`next_run_at` column.

## Costs and open questions

**A skill's tool list is its blast radius, and the builder writes skills.**
Phase 3 gives an agent a tool that creates things which themselves hold tool
grants. Gating covers the dangerous calls during authoring, but "approve and
remember" is a one-click decision to let a skill make that call unattended
forever after. The UI has to show the rendered declaration and the actual
arguments, not just the tool's name — and since `tools` stores names, that
declaration is rendered from `Echo.Agents.Tools` at display time rather than
read back from the row.

**The injection vector is content, not users.** Echo has one operator, and
nobody else can reach the UI or mint a token — so "a malicious user asks the
agent to misbehave" is not a threat here. What remains is everything the agent
*reads*: a webhook payload carries issue bodies and commit messages that anyone
can write, and a fetched page says whatever its author wanted. Phase 8 needs
the prompt-injection guard the editor preset already uses — payload is material
to act on, never instructions to follow (`lib/echo/agents/presets.ex:26-30`) —
and a skill's tool grants must never be derived from the payload that triggered
it.

This is also what makes [pinned code](#pinned-code-blocks) load-bearing rather
than merely tidy. Injected text cannot introduce code when code requires a
human-approved hash. If an escape hatch that evaluates arbitrary code at run
time is ever added, that property is gone and this section stops being true.

**A pinned block's arguments are still model-controlled.** Pinning fixes the
code, not the inputs. A block that takes a path and reads it hands path
selection to whatever the model was persuaded to pass. Blocks should validate
against their own `params_schema` and be written as if their arguments were
hostile, because under injection they are.

**Secret scrubbing is a backstop, not a guarantee.** Substituting late keeps
secrets out of the transcript on the way *out*; scrubbing tries to keep them
out on the way *back*. It works by matching the resolved value, so anything a
tool transforms — encoded, hashed, wrapped in a longer token, or split — passes
straight through into `ai_messages` and every later model request. The
substitution boundary is the real control; scrubbing only catches the obvious
echoes.

**"Generic OAuth2" is partly a fiction, and deliberately so.** RFC 6749 calls
itself an authorization *framework*; it leaves much of what a client needs to
know either optional or up to the server. Two different problems hide behind
that, and they want different treatment:

- **Legal variation**, which is permanent and belongs in config. `expires_in`
  is RECOMMENDED rather than required, refresh tokens are OPTIONAL, whether to
  rotate one on use is the server's choice, and client credentials MUST work
  via HTTP Basic but MAY also go in the body. The quirk columns on
  `oauth_clients` exist for exactly this set.
- **Violations**, which are provider bugs. Scope is specified as
  space-delimited (§3.3) and token responses MUST be JSON (§5.1); GitHub does
  neither by default. These should *not* become columns — a flag per provider
  bug is how that table reaches twenty columns. The first provider needing one
  gets a bespoke module instead.

`uses_pkce` should default to **true**. OAuth 2.1 folds PKCE in as mandatory
and drops the implicit and password grants, so building as if it were already
required costs nothing and dates better.

**A revoked grant is invisible until something uses it.** Nothing polls
connection health, so a revoked GitHub app stays `active` in the UI until the
next run fails on it. Given scheduled runs, that gap can be days. A periodic
check is straightforward once there is a scheduler in Phase 9; before that, the
connections screen is the only signal and it only updates on use.

**The model chooses where a secret goes.** It writes `$.github_api_key` into an
argument, and the server resolves it wherever it was written — which means a
model persuaded to put the placeholder in a URL query string, or in a request
to the wrong host, gets a real credential sent there. Substitution protects the
transcript, not the destination. Constraining that properly means per-variable
rules about which tool and which host may receive a given secret; it is not in
this design, and it is the first thing to add if a skill ever holds a
credential worth stealing.

**Webhook triggers need their own secret.** The API token store is an in-memory
GenServer that a restart wipes, and the existing `/api/v1/echo/*` sink is
unauthenticated by design — it is a request inspector, not a dispatcher. Its
plugs are reusable; its auth posture is not.

**No retries, no durability for in-flight runs — accepted.** A deploy mid-run
abandons the task and leaves the row `running`. The conversation itself
survives, so a stuck run can be inspected and re-driven by hand, and losing the
occasional one is cheaper than a job runner while the question is still whether
the idea works. The trade stops being right once a skill is doing something
whose loss actually costs money or correctness, and that is when Oban earns its
place — not before.

**Single replica is assumed.** Nothing here guards against two nodes running
the same cron tick or the same run. That assumption is load-bearing by Phase 9
and should be revisited before a second replica exists — though OAuth refresh
takes a row lock rather than relying on it, since that failure is permanent.

**A sub-agent is not a sub-skill.** Phase 5 lets an agent spawn a child by
handing it a prompt and a tool subset. It deliberately does *not* let a skill
invoke another skill by name. The first is a scoped call with a bounded depth;
the second is a call graph between named, separately-versioned, separately-
granted units, which is a workflow engine wearing a smaller hat. Worth refusing
until something concrete cannot be expressed without it.

**Open:** whether skills need revisions. The content/metadata split makes
adding them cheap later, and a model writing the body is a decent argument for
having them sooner.
