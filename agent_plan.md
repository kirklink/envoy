# Envoy — Autonomous Agent

## Vision

Envoy is a mostly autonomous agent that solves problems by building its own
capabilities at runtime. Give it a goal and it figures out how to get there —
including writing, analyzing, and registering new tools along the way.

What makes it different: the guardrails are structural, not trust-based. The agent
can extend itself freely, but within boundaries enforced by Dart's type system,
static analysis, and subprocess isolation. Safety isn't a prompt instruction the
LLM could ignore — it's a property of the execution model.

Over time, the agent learns about itself. It remembers what worked, what failed,
what it's curious about. It develops strategies. It gets better at its job across
sessions, not just within them.

*Envoy: a messenger dispatched to act on behalf of another. In poetry, the envoi
is the concluding stanza that carries the poem's meaning forward.*

### Inspirations and Distinctions

**OpenClaw** demonstrates that a self-extending, always-on personal agent is what
people want. Envoy shares this ambition — autonomous action, self-taught skills,
persistent memory. Where Envoy diverges is on trust: OpenClaw gives the agent full
system access and relies on the user to trust it. Envoy enforces boundaries
structurally — permission tiers, static analysis gates, sandboxed execution — so
the agent can be autonomous without being unconstrained.

**LangChain/LangFlow** are orchestration frameworks where the *developer* configures
chains and the LLM follows them. In Envoy, the *agent* decides what it needs and
builds it. The developer provides goals and guardrails, not pipelines.

---

## Design Principles

1. **Autonomy with structural safety.** The agent should be free to extend itself,
   write code, and build new capabilities — within boundaries enforced by the type
   system, static analysis, and process isolation. Not by prompt instructions.

2. **Opinionated over configurable.** Fewer choices means fewer LLM missteps. One
   correct way to define a tool, validate an input, persist state.

3. **The agent is the product.** Tools, registries, and memory are mechanisms — the
   value is an agent that solves problems autonomously and improves over time.

4. **Simple first.** Each phase must be independently useful. No phase requires the
   next to have value.

5. **Leverage what exists.** Arrow (HTTP), Endorse (validation), Stanza (persistence)
   are the runtime stack. Build the agent layer on top, not around.

6. **Don't lock in.** Abstractions at LLM provider and persistence boundaries so the
   framework isn't coupled to Anthropic or PostgreSQL.

---

## Package Architecture

Single repo (`kirklink/envoy`), two packages (currently):

```
envoy/
  envoy/          - Core: agent loop, LLM interface, conversation context, memory
  envoy_tools/    - Seed tools, dynamic tool registration, persistence (Stanza-backed)
```

`anthropic_sdk_dart` (pub.dev) is a dependency of `envoy`, not a package we build.

### How existing packages fit

| Package       | Role                                                               |
|---------------|--------------------------------------------------------------------|
| `arrow`       | HTTP interface for the agent; future MCP server endpoint           |
| `endorse`     | Validates tool inputs/outputs at execution boundary                |
| `stanza`      | Persists tool registry, session history, and agent memory          |

---

## Core Concepts

### The Agent

The central actor. An Envoy agent receives a task, reasons about how to accomplish
it, and acts — calling existing tools, writing new ones, or composing both. It
persists its work across sessions and reflects on its own experience.

The agent is not a pipeline the developer configures. It's an autonomous actor the
developer gives goals and guardrails to.

### Self-Extension

The agent's core differentiator. When the agent needs a capability it doesn't have,
it writes Dart code, submits it to `dart analyze`, and — if it passes — registers
it as a live tool. The new tool is immediately available for the current and future
sessions.

This is deeper than OpenClaw-style markdown skills: the agent writes real code that
is statically analyzed before it can execute. The type system catches errors before
they reach production. Permission tiers control what each tool can access.

**Two extension models (current and future):**

- **Dart tools** (implemented): The agent writes Dart code analyzed and sandboxed by
  the framework. Full static safety. This is the core mechanism.
- **Skill-style extensions** (future): A lighter-weight extension model — closer to
  OpenClaw's SKILL.md approach — where the agent can define capabilities as structured
  descriptions rather than code. The trust model for these needs careful design, but
  the flexibility is genuine and worth exploring.

### Helper Agents (Future)

The main agent may not need to do everything itself. A future direction is for the
primary agent to spawn or access specialized helper agents — delegating code
development, quality review, writing tasks, or design work to focused sub-agents
that operate within the permissions the main agent authorizes.

The exact patterns here are still emerging. The tool registry and permission model
are designed not to preclude multi-agent coordination.

### Tools

The atomic unit of capability. Tools are either **static** (shipped with
`envoy_tools`) or **dynamic** (written by the agent at runtime). Both follow the
same interface:

- `name`, `description`, `inputSchema` (JSON Schema), `permission` tier
- Validated by Endorse before execution
- Dynamic tools run as sandboxed subprocesses with tier-specific package access

The agent searches the tool registry (FTS) before writing new tools — it reuses
what it's already built.

### Agent Loop

```
1. Task arrives (CLI or HTTP)
2. Load conversation history (EnvoyContext)
3. [Future] Inject relevant memory (character, strategy, prior experience)
4. LLM call: task + history + memory + tool schemas → response
5. If tool call requested:
   a. search_tools → check registry → call existing, or write + register new
   b. validate inputs (Endorse) → execute in sandbox → append result → goto 4
6. If text response: persist session → return to caller
7. [Post-task] agent.reflect() — agent writes self-memory entries
```

Max iterations are bounded. On failure, the loop surfaces the error to the LLM once
for recovery before escalating to the caller.

### Memory

Three distinct layers with different storage, retrieval, and lifetime:

**Conversation history** (`EnvoyContext`)
- Sequential log of messages + tool results within and across sessions
- Temporal and append-only; pruned to fit token budget
- Stored in Stanza; session transcripts retained by policy

**Agent self-memory** (`AgentMemory` / `reflect()`)
- What the agent knows about *itself as an actor*: what it has built, what approaches
  worked, where it got stuck, what it wants to explore, and who it is
- Not a log and not project documentation — entries are the agent's own perspective
  on its experience, written in its voice
- Written via post-task reflection (a separate LLM call outside the task loop)
- Distinct from user memory and session history

The distinction matters: history answers *what happened*, memory answers
*what I know about myself*.

**Five memory types (target model):**

| Type | Description |
|------|-------------|
| `character` | Who I am and how I work. Developer-seeded, agent-amendable. Always-on. |
| `tools` | What's in my toolbox. Auto-derived from the tool registry. |
| `success` | Things I accomplished. Episodic entries with outcome and context. |
| `failure` | Things that didn't work and why. Prevents repeating dead ends. |
| `curiosity` | Observations worth exploring later. Forward-looking margin notes. |
| `strategy` | Emergent patterns synthesized from success + failure. Earned, not assumed. |

**Injection model (target):**
- `character` → injected every session start
- `tools` → injected at task start (live projection of registry)
- relevant `strategy`, `success`, `failure`, `curiosity` → FTS-matched before similar work

**Spare time mode (future):** A run mode with no task, where the agent is handed its
`curiosity` log and a workspace and told to explore — building tools or strategies
it files back into memory.

*The agent may eventually build its own memory system from this foundation.*

---

## Interaction Model

### Phase 1: CLI
```
dart run envoy "describe task here"
dart run envoy --session abc123 "continue from last session"
```
Simplest surface. Good for development and single-task automation.

### Phase 2: HTTP (Arrow)
```
POST /envoy/task         { task, session_id? }
GET  /envoy/session/:id  conversation history
GET  /envoy/tools        tool registry
```
Arrow handles routing, middleware (auth, logging), and response envelope.
Enables programmatic use and multi-turn conversations over HTTP.

### Phase 3: MCP Server (Arrow annotation layer)
Arrow routes annotated with `@McpTool` are exposed as MCP-compatible tools,
making the agent's capabilities discoverable by any MCP client (including
Claude Desktop, other agents, IDE extensions).

---

## Security Model

### Permission Tiers (declared, not enforced by generated code)

| Tier | Permissions                          | Granted by         |
|------|--------------------------------------|--------------------|
| 0    | Pure computation only                | Always             |
| 1    | Filesystem read (scoped to workspace)| Default for agent  |
| 2    | Filesystem write (scoped)            | Explicit config    |
| 3    | Network access (allowlist)           | Explicit config    |
| 4    | Process spawning                     | Explicit config    |

Tools declare their tier. The runner enforces the tier at execution time via
subprocess flags and filesystem restrictions — the tool file itself is not trusted
to self-limit.

### Subprocess Isolation

Dynamic tools always run as `dart run <tool_file> <json_input>` in a subprocess.
- Memory: isolated (Dart VM per subprocess)
- Filesystem: scoped via working directory + explicit path checks
- Network: allowlist enforced at policy level (future: network namespace)
- Timeout: hard limit on every tool execution

---

## Phased Roadmap

### Phase 0 — Unblocking dependency
- [x] Adopt `anthropic_sdk_dart` (pub.dev, langchaindart.dev) **[validated]**
  - Unofficial but actively maintained; v0.3.1, updated December 2025
  - Risk: unofficial status; migration cost if Anthropic ships an official Dart SDK
  - Validation checklist:
    - [x] Messages API round-trip works
    - [x] Streaming works end-to-end
    - [x] Tool use / function calling works with our schema format

### Phase 1 — Envoy skeleton **[done]**
- [x] `envoy`: core loop with hardcoded no-op tools
  - `EnvoyContext` (conversation history, token budget management)
  - `Tool` interface + `ToolResult`
  - Loop: LLM call → tool dispatch → iterate
  - CLI entrypoint (`dart run envoy`)
  - No persistence yet (in-memory only)
- [x] `OnToolCall` observer callback — fires after every tool execution

### Phase 2 — Seed tools **[done]**
- [x] `envoy_tools`: standard tool library
  - `read_file`, `write_file` (tier 1/2, workspace-scoped, path traversal blocked)
  - `fetch_url` (tier 3, injectable `http.Client` for testability)
  - `run_dart` (tier 4, executes arbitrary Dart subprocess; `path` or inline `code`)
- [ ] Wire Endorse into tool input validation *(deferred — not blocking)*

### Phase 3 — Dynamic tools **[3a done, 3b pending]**

#### 3a — In-memory dynamic registration **[done]**
- [x] `DynamicTool`: wraps a `.dart` script path + schema; subprocess I/O contract:
  receive JSON as `args[0]`, write `{"success": bool, "output"/"error": str}` to stdout;
  `main()` may be async
- [x] `RegisterToolTool`: meta-tool that writes code to per-tier runner dir,
  runs `dart analyze` (errors block, warnings pass), fires `onToolRegister` review gate,
  creates `DynamicTool`, calls `onRegister`
- [x] `EnvoyAgent.registerTool(Tool)`: mutates the live tool map; loop reads schemas fresh
  each iteration so new tools are immediately visible to the LLM
- [x] `ToolRunner`: per-tier runner projects at `<workspace>/.envoy/runners/<tier>/`;
  each tier gets only its allowed packages (enforced via pubspec); `dart pub get` once per tier
- [x] `OnToolRegister` callback: human-in-the-loop gate called after analysis, before
  registration; returning `false` deletes the file and blocks the tool
- [x] Package grants by tier: `compute`=dart:core; `readFile/writeFile`=+path; `network/process`=+http+path
- [x] Setup: `agent.registerTool(RegisterToolTool(root, onRegister: agent.registerTool, onToolRegister: ...))`

#### 3b — Persistence **[done]**
- [x] `StanzaEnvoyStorage`: Stanza-backed tool registry + session history
  - `initialize()` — idempotent `CREATE TABLE IF NOT EXISTS` for `envoy_tools`,
    `envoy_sessions`, `envoy_messages`
  - `saveTool(DynamicTool)` — upserts by name (ON CONFLICT DO UPDATE)
  - `loadTools()` — returns `List<DynamicTool>` (reconstructed via `DynamicTool.fromMap`)
  - `ensureSession([id])` — creates or restores a session; initializes sort order counter
  - `loadMessages(sessionId)` — returns `List<anthropic.Message>` ordered by `sort_order`
  - `appendMessage(sessionId, message)` — persists each message with sequential sort order
- [x] `DynamicTool.toMap()` / `DynamicTool.fromMap()` — round-trip serialization
- [x] `EnvoyContext(onMessage: ..., messages: [...])` — hook for message persistence + session restore
- [x] Endorse-backed JSON Schema validation via `SchemaValidatingTool` mixin on all tools
- [x] Tool deduplication: `toolExists` callback on `RegisterToolTool`; `EnvoyAgent.hasTool/getTool`;
  example uses `_toolIsAvailable` (checks registry + script file existence); stable workspace path
- [x] `SearchToolsTool`: FTS over `envoy_tools` table via `StanzaEnvoyStorage.searchTools(query)`;
  `register_tool` description updated to "call search_tools first"; LLM now follows
  search → try existing → register only if nothing matches (first real-world stanza FTS use)

### Phase 4 — Lore (Agent Self-Memory)

#### 4a — Minimal store **[done]**

Build the store, not the system. Observe what the agent wants to remember before
designing the surfacing mechanism. The agent chooses its own type labels — no prescribed taxonomy.

- [x] `MemoryEntry` + `AgentMemory` interface → `envoy/lib/src/memory.dart` (core)
- [x] `MemoryEntity` + `memory_entity.g.dart` (build_runner generated)
      → `envoy_tools/lib/src/persistence/`
- [x] `StanzaMemoryStorage implements AgentMemory` → same persistence dir
- [x] `EnvoyAgent(memory: AgentMemory?)` — optional constructor parameter
- [x] `EnvoyAgent.reflect()` — post-task LLM call over session history; agent writes
      0–3 JSON entries with self-chosen type labels; stored via `AgentMemory.remember()`
- [x] Memory is not a tool — consolidation happens outside the task loop as a
      separate LLM call; session context is not modified
- [x] Wired into `persistence_example.dart`: `reflect()` after each run, memories printed
- [x] Fixed stanza: `annotations.dart` now exports schema types needed by generated `$schema` getters

#### 4b — Injection model (after observation)

Design the surfacing/injection model based on what the agent actually stores in 4a.
Informed by real agent behavior, not assumed patterns.

- [ ] Type-specific tables if natural categories emerge
- [ ] Auto-inject `character` at session start
- [ ] Auto-derive `tools` from registry at task start
- [ ] FTS-query `success`/`failure`/`strategy` before similar work
- [ ] Surface overlapping `curiosity` at session start or task time
- [ ] Character seeding (developer-authored initial identity)

#### 4c — Spare time mode (future)

- [ ] Run mode with no task: agent handed `curiosity` log + workspace, told to explore
- [ ] Lets the agent follow its own interests between directed sessions
- [ ] Outcomes filed back into Lore (tools registered, strategies noted)

### Phase 5 — HTTP interface
- [ ] Arrow integration: expose envoy as HTTP API
- [ ] Multi-turn conversation over HTTP (session continuity)

### Phase 6 — MCP
- [ ] Arrow `@McpTool` annotation + code generation
- [ ] Envoy exposes capabilities as MCP server

---

## Open Questions (deferred, not blocking)

1. **Helper agents**: How does the primary agent delegate to specialized sub-agents?
   Code review, writing, design — focused agents operating within authorized permissions.
   The tool registry and permission tiers shouldn't preclude this. Patterns will emerge.

2. **Provider abstraction**: How thin is the LLM client interface? Start Anthropic-only,
   define the interface boundary so switching providers doesn't require rewriting the loop.

3. **Context window strategy**: Simple sliding window first. Smarter summarization
   (ask LLM to summarize older context) is a Phase 3+ concern.

4. **Tool versioning**: If a dynamic tool is updated, old executions referenced in
   history may behave differently on replay. Probably immutable tool versions with a
   new registration on change.

5. **Streaming UX**: The loop needs streaming to feel responsive. Arrow may need
   streaming response support. Audit before Phase 5.

6. **Allowlist enforcement for network tools**: Phase 2 defers this. Phase 3b should
   address before any production use.

7. **Dynamic tool I/O via args vs stdin**: Currently JSON input is passed as `args[0]`.
   Works for Phase 3a; large inputs may hit OS arg-length limits. Migrate to stdin pipe
   before production use.

8. **Dynamic tool package context**: ~~Tools can only use `dart:` core libs today.~~ **[resolved]**
   `ToolRunner` initializes a minimal Dart project at `<workspace>/.envoy/` with `http` and
   `path` as dependencies. Scripts in `.envoy/tools/` inherit this context via `dart`'s
   pubspec walk. `dart pub get` runs once lazily on first registration.

---

## Non-Goals (explicit scope boundaries)

- **Not an orchestration framework.** Envoy is an autonomous agent, not a tool for
  developers to wire up LLM chains. The agent decides how to solve problems.
- **Not trust-based safety.** We don't rely on prompts to constrain the agent.
  Guardrails are structural — enforced by the type system and execution model.
- **Not multi-modal (yet).** Text and structured data only. Images/audio out of scope.
- **Not a hosted service.** Runs locally or self-hosted. No cloud orchestration layer.
- **Not model-agnostic from day one.** Anthropic first. Abstraction added when a
  second provider is actually needed, not speculatively.

## Open Directions (longer-term, exploratory)

- **Skill-style extensions**: A lighter extension model alongside Dart tools —
  structured descriptions (closer to OpenClaw's SKILL.md) that lower the barrier
  to teaching the agent new workflows. Trust model needs careful design.
- **Helper agent delegation**: Primary agent spawns specialized sub-agents for
  focused work (code development, review, writing, design). Sub-agents operate
  within permissions the primary agent authorizes.
- **Proactive behavior**: Agent acts on a schedule or in response to events,
  not just when prompted. Heartbeat checks, curiosity-driven exploration,
  background tool maintenance.
