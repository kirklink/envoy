# Envoy — Dart Agentic Framework

Lightweight, opinionated agentic framework where an LLM can extend its own
capabilities at runtime by writing, registering, and executing new tools.
Security and correctness emerge from the language and type system, not from
framework rules that generated code could bypass.

## Package Structure

Single repo (`kirklink/envoy`), two packages (third — `envoy_lore` — is Phase 4):

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

### Seed tools (`envoy_tools/lib/src/`)

| Tool | Class | Permission | Notes |
|------|-------|------------|-------|
| `read_file` | `ReadFileTool` | `readFile` | Workspace-scoped; path traversal blocked |
| `write_file` | `WriteFileTool` | `writeFile` | Creates parent dirs; path traversal blocked |
| `fetch_url` | `FetchUrlTool` | `network` | Injectable `http.Client` for testability |
| `run_dart` | `RunDartTool` | `process` | `path` or inline `code`; configurable timeout |
| `register_tool` | `RegisterToolTool` | `process` | Meta-tool; see Dynamic Tools below |

### Dynamic tools

`RegisterToolTool` + `DynamicTool` implement the self-extension mechanic:

1. Agent calls `register_tool` with Dart source implementing the I/O contract
2. Code written to `<workspace>/.envoy/tools/<name>.dart`
3. `dart analyze` runs — errors block registration, warnings pass
4. `DynamicTool` wraps the script path + schema and is added to the live tool map
5. LLM can call the new tool on the very next iteration

**Dynamic tool I/O contract** (script must follow):
- Receive JSON-encoded input as `args[0]`
- Print `{"success": true, "output": "..."}` or `{"success": false, "error": "..."}` to stdout
- Only `dart:` core libraries available (no `package:` imports)

## Key Files

```
envoy/
  lib/src/agent.dart        - EnvoyAgent, EnvoyConfig, OnToolCall typedef
  lib/src/context.dart      - EnvoyContext (conversation history + pruning)
  lib/src/tool.dart         - Tool (abstract), ToolResult, ToolPermission
  lib/envoy.dart            - Public exports
  bin/envoy.dart            - CLI entrypoint
  example/
    validate_anthropic.dart - Phase 0: SDK smoke test
    basic_tool_example.dart - Simple tool use demo

envoy_tools/
  lib/src/
    read_file_tool.dart     - ReadFileTool
    write_file_tool.dart    - WriteFileTool
    fetch_url_tool.dart     - FetchUrlTool
    run_dart_tool.dart      - RunDartTool
    dynamic_tool.dart       - DynamicTool (subprocess wrapper for registered tools)
    register_tool_tool.dart - RegisterToolTool (meta-tool; analyze + register)
    envoy_tools.dart        - EnvoyTools.defaults() factory
  lib/envoy_tools.dart      - Public exports
  test/envoy_tools_test.dart
  example/
    tools_example.dart      - Phase 2: write + run a Dart script
    watch_example.dart      - onToolCall visibility demo
    dynamic_tool_example.dart - Phase 3a: agent self-registers caesar_cipher
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

final response = await agent.run('Write hello.dart and run it.');
```

### With dynamic tool registration

```dart
final agent = EnvoyAgent(
  EnvoyConfig(apiKey: apiKey),
  tools: EnvoyTools.defaults(workspaceRoot),
);

// Wire register_tool into the agent's own tool map
agent.registerTool(
  RegisterToolTool(workspaceRoot, onRegister: agent.registerTool),
);

// Now the agent can write and register new tools itself
final response = await agent.run(
  'Create a tool that converts Celsius to Fahrenheit, then use it for 100°C.',
);
```

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

- **`dart analyze` without pubspec**: `RegisterToolTool` runs `dart analyze` on a standalone
  file. This works for `dart:` core libs. Exit code 0 = clean; non-zero = blocked.

- **Dynamic tool args limit**: JSON input is passed as `args[0]`. Works for typical inputs;
  large payloads may hit OS argument-length limits. See open question #7 in `agent_plan.md`.

- **`EnvoyTools.defaults()` does not include `register_tool`**: Self-extension is opt-in.
  Add it explicitly with `agent.registerTool(RegisterToolTool(..., onRegister: agent.registerTool))`.

- **Path traversal**: `ReadFileTool` and `WriteFileTool` normalize and check that resolved
  paths start with `workspaceRoot` before any I/O. `../../etc/passwd` → error.

- **Roadmap**: `agent_plan.md` at workspace root. Phases 0–3a done; 3b (Stanza persistence),
  4 (envoy_lore), 5 (Arrow HTTP), 6 (MCP) pending.
