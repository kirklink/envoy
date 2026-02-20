# Envoy — Dart Agentic Framework

Lightweight, opinionated agentic framework where an LLM can extend its own
capabilities at runtime by writing, registering, and executing new tools.
Security and correctness emerge from the language and type system, not from
framework rules that generated code could bypass.

## Package Structure

Single repo (`kirklink/envoy`), two packages:

```
envoy/          - Core: agent loop, LLM interface, Tool interface, conversation context
envoy_tools/    - Seed tools: file I/O, HTTP, Dart subprocess, dynamic tool registration
```

Both packages live inside the `envoy/` submodule directory.

## Architecture

### Agent loop (`envoy/lib/src/agent.dart`)

```
task → EnvoyContext.addUser → for (iterations):
  LLM call (messages + tool schemas) → response
  if tool_use blocks → dispatch each tool → EnvoyContext.addToolResult → repeat
  if text only → return text
```

- `EnvoyAgent` holds `Map<String, Tool> _tools` (mutable — `registerTool()` mutates it live)
- `_toolSchemas()` reads the map fresh each iteration — newly registered tools are immediately visible
- `OnToolCall` callback fires after each tool execution (logging, progress, debugging)
- `EnvoyConfig`: `apiKey`, `model`, `maxTokens`, `maxIterations`
- System prompt (`systemPrompt:` on `EnvoyAgent`, default provided) sent with every LLM call
  including `reflect()` — establishes agent identity and behavior (ask for help when stuck, etc.)

### Tool interface (`envoy/lib/src/tool.dart`)

```dart
abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;   // JSON Schema passed to the LLM
  ToolPermission get permission;
  Future<ToolResult> execute(Map<String, dynamic> input);
}
```

Permission tiers: `compute < readFile < writeFile < network < process`

`ToolResult` is either `ToolResult.ok(output)` or `ToolResult.err(message)`.

### Conversation context (`envoy/lib/src/context.dart`)

- Stores `List<anthropic.Message>` — user turns, assistant turns, tool results
- Token budget pruning at 80% of `maxTokens`: removes oldest message pairs
- `addUser()`, `addAssistant()`, `addToolResult()`, `estimatedTokens`

### Tool input validation (`envoy_tools/lib/src/schema_validator.dart`)

All tools mix in `SchemaValidatingTool`, which calls `SchemaValidator.validate(input, inputSchema)`
before `execute()`. The validator maps JSON Schema `required` + `type` fields to Endorse rules.
Returns `ToolResult.err(...)` on failure — execution never reaches `execute()`.

Supported `type` values: `string`, `integer`, `number`, `boolean`, `array`, `object`.

### Seed tools (`envoy_tools/lib/src/`)

| Tool | Class | Permission | Notes |
|------|-------|------------|-------|
| `read_file` | `ReadFileTool` | `readFile` | Workspace-scoped; path traversal blocked |
| `write_file` | `WriteFileTool` | `writeFile` | Creates parent dirs; path traversal blocked |
| `fetch_url` | `FetchUrlTool` | `network` | Auto-converts HTML→markdown; configurable size cap; injectable `http.Client` |
| `run_dart` | `RunDartTool` | `process` | `path` or inline `code`; configurable timeout |
| `ask_user` | `AskUserTool` | `compute` | Callback-based; included in `defaults()` when `onAskUser` provided |
| `search_tools` | `SearchToolsTool` | `network` | FTS over persisted tool registry; call before `register_tool` |
| `register_tool` | `RegisterToolTool` | `process` | Meta-tool; always search first — see Dynamic Tools below |

All static tools + `DynamicTool` have `SchemaValidatingTool` mixed in.

### Dynamic tools

`RegisterToolTool` + `DynamicTool` implement the self-extension mechanic:

1. Agent calls `register_tool` with Dart source and a declared permission tier
2. `ToolRunner.ensure()` initializes the tier-specific runner project (idempotent)
3. Code written to `<workspace>/.envoy/runners/<tier>/tools/<name>.dart`
4. `dart analyze` runs — errors block registration, warnings pass
5. `onToolRegister` callback fires if set — human can review code and approve/deny
6. `DynamicTool` wraps the script path + schema and is added to the live tool map
7. LLM can call the new tool on the very next iteration

**Dynamic tool I/O contract** (script must follow):
- Receive JSON-encoded input as `args[0]`
- Print `{"success": true, "output": "..."}` or `{"success": false, "error": "..."}` to stdout
- `main()` may be `async`

**Available packages by permission tier** (enforced — tools literally can't import beyond their tier):

| Tier        | Available packages       |
|-------------|--------------------------|
| `compute`   | `dart:` core only        |
| `readFile`  | + `package:path`         |
| `writeFile` | + `package:path`         |
| `network`   | + `package:http` + path  |
| `process`   | + `package:http` + path  |

Runner projects live at `<workspace>/.envoy/runners/<tier>/`. Each has its own
`pubspec.yaml` and `.dart_tool/`. `dart pub get` runs once per tier, lazily.

## Key Files

```
envoy/
  lib/src/agent.dart        - EnvoyAgent, EnvoyConfig, OnToolCall typedef
  lib/src/run_result.dart   - RunResult, RunOutcome, TokenUsage, ToolCallRecord
  lib/src/context.dart      - EnvoyContext (conversation history + pruning)
  lib/src/memory.dart       - MemoryEntry, AgentMemory (interface)
  lib/src/tool.dart         - Tool (abstract), ToolResult, ToolPermission
  lib/envoy.dart            - Public exports
  bin/envoy.dart            - CLI entrypoint
  example/
    validate_anthropic.dart - Phase 0: SDK smoke test
    basic_tool_example.dart - Simple tool use demo

envoy_tools/
  lib/src/
    ask_user_tool.dart      - AskUserTool (callback-based user interaction)
    read_file_tool.dart     - ReadFileTool
    write_file_tool.dart    - WriteFileTool
    fetch_url_tool.dart     - FetchUrlTool
    run_dart_tool.dart      - RunDartTool
    dynamic_tool.dart       - DynamicTool (subprocess wrapper for registered tools)
    register_tool_tool.dart - RegisterToolTool (meta-tool; analyze + register)
    schema_validator.dart   - SchemaValidator (JSON Schema → Endorse rules)
    schema_validating_tool.dart - SchemaValidatingTool mixin
    envoy_tools.dart        - EnvoyTools.defaults() factory
    persistence/
      stanza_entities.dart      - ToolRecordEntity, SessionEntity, MessageEntity
      stanza_entities.g.dart    - Generated Stanza table/entity code
      stanza_storage.dart       - StanzaEnvoyStorage (tool registry + session history)
      search_tools_tool.dart    - SearchToolsTool (FTS over persisted registry)
      memory_entity.dart        - MemoryEntity (@StanzaEntity for envoy_memory table)
      memory_entity.g.dart      - Generated Stanza table/entity code
      stanza_memory_storage.dart - StanzaMemoryStorage (implements AgentMemory)
  lib/envoy_tools.dart      - Public exports
  test/envoy_tools_test.dart
  example/
    tools_example.dart        - Phase 2: write + run a Dart script
    watch_example.dart        - onToolCall visibility demo
    dynamic_tool_example.dart - Phase 3a: agent self-registers caesar_cipher
    package_tool_example.dart - Phase 3a: agent uses package:http in a dynamic tool
    persistence_example.dart  - Phase 3b+4a: session, registry, and agent memory (full demo)
```

## Commands

```bash
# From envoy/ or envoy_tools/
dart pub get
dart test
dart analyze

# Run examples (requires ANTHROPIC_API_KEY)
export ANTHROPIC_API_KEY=...                              # or: source ../.env
dart run example/watch_example.dart                       # from envoy_tools/
dart run example/dynamic_tool_example.dart                # from envoy_tools/
```

## Branch

- `main` — active development (no separate feature branches yet)

## Using Envoy

### Basic agent

```dart
import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';

final agent = EnvoyAgent(
  EnvoyConfig(apiKey: apiKey, model: 'claude-haiku-4-5-20251001'),
  tools: EnvoyTools.defaults(workspaceRoot),
  onToolCall: (name, input, result) => print('[$name] ${result.output}'),
);

final result = await agent.run('Write hello.dart and run it.');
print(result.response);      // final text
print(result.outcome);        // completed, maxIterations, or error
print(result.errorMessage);   // non-null when outcome is error
print(result.tokenUsage);     // aggregated across all LLM calls
print(result.toolCalls);      // ordered log of every tool invocation
```

### With dynamic tool registration

```dart
final agent = EnvoyAgent(
  EnvoyConfig(apiKey: apiKey),
  tools: EnvoyTools.defaults(workspaceRoot),
);

// Wire register_tool — with optional human review gate
agent.registerTool(
  RegisterToolTool(
    workspaceRoot,
    onRegister: agent.registerTool,
    onToolRegister: (name, permission, code) async {
      // Show code to user, return true to allow or false to block
      print('Agent wants to register "$name" (${permission.name} tier):\n$code');
      stdout.write('Allow? [y/N] ');
      return stdin.readLineSync()?.toLowerCase() == 'y';
    },
  ),
);

// Now the agent can write and register new tools itself
final result = await agent.run(
  'Create a tool that converts Celsius to Fahrenheit, then use it for 100°C.',
);
```

### With persistence (Phase 3b)

```dart
import 'package:stanza/stanza.dart';
import 'package:envoy_tools/envoy_tools.dart';

final storage = StanzaEnvoyStorage(Stanza.url('postgresql://...'));
await storage.initialize();              // CREATE TABLE IF NOT EXISTS (idempotent)

// New session, or pass a previous ID to restore:
final sessionId = await storage.ensureSession();

final context = EnvoyContext(
  messages: await storage.loadMessages(sessionId), // empty for new session
  onMessage: (msg) => storage.appendMessage(sessionId, msg),
);

final agent = EnvoyAgent(config, context: context, tools: EnvoyTools.defaults(root));

// Restore previously registered dynamic tools:
for (final tool in await storage.loadTools()) {
  agent.registerTool(tool);
}

// Registry search — LLM calls this before register_tool:
agent.registerTool(SearchToolsTool(storage));

// Persist newly registered tools; dedup guard prevents re-registering live tools:
agent.registerTool(RegisterToolTool(
  workspaceRoot,
  toolExists: (name) {
    final tool = agent.getTool(name);
    if (tool == null) return false;
    if (tool is DynamicTool) return File(tool.scriptPath).existsSync();
    return true;
  },
  onRegister: (tool) {
    agent.registerTool(tool);
    if (tool is DynamicTool) storage.saveTool(tool);
  },
));
```

`StanzaEnvoyStorage` methods:
- `initialize()` — idempotent DDL; call every startup
- `ensureSession([id])` — creates or restores a session
- `loadMessages(sessionId)` → `List<anthropic.Message>` ordered by sort_order
- `appendMessage(sessionId, message)` — called automatically via `onMessage`
- `loadTools()` → `List<DynamicTool>` (full registry)
- `saveTool(tool)` — upserts by name
- `searchTools(query)` → `List<Map<String,String>>` — FTS on name + description, ranked by `ts_rank`

### With agent memory (Phase 4a)

```dart
import 'package:stanza/stanza.dart';
import 'package:envoy_tools/envoy_tools.dart';

final memory = StanzaMemoryStorage(Stanza.url('postgresql://...'));
await memory.initialize();   // creates envoy_memory table (idempotent)

final agent = EnvoyAgent(
  config,
  context: context,
  memory: memory,
  tools: EnvoyTools.defaults(root),
);

final result = await agent.run(task);

// Post-task reflection: agent decides what to remember about itself.
// Makes a separate LLM call — does not modify session context.
await agent.reflect();

// Inspect what the agent stored:
final entries = await memory.recall();
for (final e in entries) print('[${e.type}] ${e.content}');

// Filter by type or FTS query:
final failures = await memory.recall(type: 'failure');
final relevant = await memory.recall(query: 'tool registration');
```

`StanzaMemoryStorage` methods:
- `initialize()` — idempotent DDL; call every startup
- `remember(MemoryEntry)` — persist one entry (called by `reflect()` automatically)
- `recall({type?, query?})` → `List<MemoryEntry>` — filter by type and/or FTS; newest first

### Writing a static tool

```dart
class MyTool extends Tool {
  @override String get name => 'my_tool';
  @override String get description => 'Does something useful.';
  @override Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'value': {'type': 'string', 'description': 'Input value'},
    },
    'required': ['value'],
  };
  @override ToolPermission get permission => ToolPermission.compute;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final value = input['value'] as String?;
    if (value == null) return const ToolResult.err('value is required');
    return ToolResult.ok('processed: $value');
  }
}
```

## Key Things to Know

- **`anthropic` import alias**: `agent.dart` imports `anthropic_sdk_dart` as `anthropic`
  to avoid collision with our own `Tool` class. Both packages define `Tool`.

- **`_tools` is mutated in place**: `registerTool()` adds to the map; `_toolSchemas()`
  reads it each iteration. No restart needed — tools registered mid-run are live immediately.

- **Per-tier runner projects**: `ToolRunner.ensure(root, permission)` creates a separate
  Dart project per tier under `<workspace>/.envoy/runners/<tier>/`. `dart analyze` and
  `dart run` both walk up to find that tier's `pubspec.yaml`, so package availability is
  structurally enforced — a `compute` tool literally cannot resolve `package:http`.

- **Dynamic tool args limit**: JSON input is passed as `args[0]`. Works for typical inputs;
  large payloads may hit OS argument-length limits. See open question #7 in `agent_plan.md`.

- **System prompt**: `EnvoyAgent(systemPrompt: ...)` — optional, with a sensible default.
  Sent with every `_llmCall()` and `reflect()`. Establishes identity (Envoy), behavior
  (ask for help when stuck, search before registering, think step by step). Override to
  customize agent personality or add domain-specific instructions.

- **`AskUserTool`**: Callback-based — the tool calls `OnAskUser(question)` and returns the
  answer. Included in `EnvoyTools.defaults()` when `onAskUser:` is provided. Gives the agent
  an escape hatch to request human input instead of burning through iterations when stuck.

- **`RunResult`**: `run()` returns `RunResult` instead of `String`. Contains `response` (text),
  `outcome` (`completed`/`maxIterations`/`error`), `iterations`, `duration`, `tokenUsage` (aggregated
  across all LLM calls), `toolCalls` (ordered log of every invocation with per-tool timing,
  plus `reasoning` — the agent's thinking text from each iteration), and optional `errorMessage`.
  No more exceptions — check `result.outcome` instead.

- **API error handling**: The agent loop retries transient errors (429 rate limit, 529 overloaded)
  with exponential backoff (2s, 4s, 8s — up to 3 retries). Non-retryable errors return
  `RunResult(outcome: error, errorMessage: ...)` instead of crashing. `reflect()` silently
  skips on API errors (best-effort).

- **`fetch_url` HTML-to-markdown**: HTML responses (detected via `content-type` header) are
  automatically converted to clean markdown using `html2md`, with `<script>` and `<style>`
  elements stripped. Non-HTML (JSON, XML, text) passes through unchanged. Output is capped
  at `maxResponseLength` (default 32K chars / ~8K tokens) with a truncation notice. Configurable
  via `FetchUrlTool(maxResponseLength: ...)` or `EnvoyTools.defaults(fetchMaxResponseLength: ...)`.

- **`EnvoyTools.defaults()` does not include `register_tool`**: Self-extension is opt-in.
  Add it explicitly with `agent.registerTool(RegisterToolTool(..., onRegister: agent.registerTool))`.

- **Path traversal**: `ReadFileTool` and `WriteFileTool` normalize and check that resolved
  paths start with `workspaceRoot` before any I/O. `../../etc/passwd` → error.

- **Input validation**: Every static tool and `DynamicTool` mixes in `SchemaValidatingTool`.
  The agent loop calls `tool.validateInput(input)` before `tool.execute(input)`. Bad inputs
  return `ToolResult.err(...)` — `execute()` is never called.

- **Persistence pattern**: `StanzaEnvoyStorage` is opt-in. Wire it via `EnvoyContext(onMessage:
  ..., messages: ...)` for session history, and the `onRegister` callback for tool registry.
  The agent itself has no storage dependency — see `persistence_example.dart`.

- **`DynamicTool.toMap()` / `DynamicTool.fromMap()`**: Round-trip serialization for storage.
  `inputSchema` is JSON-encoded as a string. `permission` is stored as the enum name.

- **Tool deduplication**: `RegisterToolTool` accepts a `toolExists` callback. Pass a closure
  that checks both registry presence and script file existence (`DynamicTool.scriptPath`).
  `EnvoyAgent.hasTool(name)` checks in-memory registry; `getTool(name)` returns the `Tool`.

- **Search before register**: `SearchToolsTool` uses `StanzaEnvoyStorage.searchTools()` to
  run FTS (PostgreSQL `to_tsvector`/`plainto_tsquery`) over name and description. The
  `register_tool` description instructs the LLM to call `search_tools` first — if a matching
  tool is found, the LLM calls it directly without writing new code.

- **Agent memory**: `AgentMemory` interface in `envoy` core; `StanzaMemoryStorage` in
  `envoy_tools`. Pass `memory:` to `EnvoyAgent`. Call `agent.reflect()` after `run()` —
  it makes a separate LLM call, does not touch the session context, and stores whatever
  the agent considers worth keeping. No prescribed type taxonomy — agent chooses its own labels.

- **`stanza/annotations.dart` exports schema types**: The `stanza_builder` code generator
  produces a `$schema` getter on table classes that references `SchemaTable`, `SchemaColumn`,
  `ColumnType`. These are now exported from `annotations.dart` so entity files work without
  importing `stanza.dart` directly.

- **Roadmap**: `agent_plan.md` in repo root. Phases 0–3b + 4a done; 4b (injection),
  5 (Arrow HTTP), 6 (MCP) pending.
