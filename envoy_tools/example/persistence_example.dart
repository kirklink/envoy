// Persistence demo: tool registry + session history via Stanza.
//
// Shows how to:
//   1. Initialize StanzaEnvoyStorage and create/restore a session
//   2. Load previously registered dynamic tools on startup
//   3. Hook EnvoyContext.onMessage for automatic message persistence
//   4. Persist newly registered tools via the onRegister callback
//
// Two-run demo:
//   Run #1 (no args): registers caesar_cipher, uses it, session is persisted.
//   Run #2 (pass session ID from run #1): restores history + registered tools,
//           asks a follow-up question using the already-registered tool.
//
// Requires: DATABASE_URL and ANTHROPIC_API_KEY environment variables.
// Example DATABASE_URL: postgresql://user:pass@localhost:5432/envoy_dev

import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';
import 'package:stanza/stanza.dart';

/// Returns true only when the tool is registered AND its script file exists.
///
/// Prevents re-registration of in-memory tools whose scripts are still on
/// disk, while allowing recovery when a script has been deleted.
bool _toolIsAvailable(EnvoyAgent agent, String name) {
  final tool = agent.getTool(name);
  if (tool == null) return false;
  if (tool is DynamicTool) return File(tool.scriptPath).existsSync();
  return true;
}

Future<void> main(List<String> args) async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final dbUrl = Platform.environment['DATABASE_URL'];
  if (dbUrl == null || dbUrl.isEmpty) {
    stderr.writeln('ERROR: DATABASE_URL not set');
    exit(1);
  }

  // ── Storage setup ─────────────────────────────────────────────────────────

  final storage = StanzaEnvoyStorage(Stanza.url(dbUrl));
  await storage.initialize(); // idempotent — safe to call every startup

  // Restore an existing session or start a new one.
  final existingSessionId = args.isNotEmpty ? args[0] : null;
  final sessionId = await storage.ensureSession(existingSessionId);
  final isResuming = existingSessionId != null;

  print(isResuming
      ? 'Resuming session: $sessionId'
      : 'New session: $sessionId  (pass this as arg[0] to resume)');
  print('');

  // ── Context restoration ───────────────────────────────────────────────────

  // Load previous messages (empty list for a new session).
  final priorMessages = await storage.loadMessages(sessionId);
  print('Loaded ${priorMessages.length} prior message(s) from storage.');

  final context = EnvoyContext(
    messages: priorMessages,
    onMessage: (msg) => storage.appendMessage(sessionId, msg),
  );

  // ── Agent setup ───────────────────────────────────────────────────────────

  // Use a stable directory so dynamic tool scripts survive between runs.
  final workspaceRoot = '${Directory.systemTemp.path}/envoy_persist_example';
  await Directory(workspaceRoot).create(recursive: true);

  final agent = EnvoyAgent(
    EnvoyConfig(
      apiKey: apiKey,
      model: 'claude-haiku-4-5-20251001',
      maxTokens: 4096,
    ),
    context: context,
    tools: EnvoyTools.defaults(workspaceRoot),
    onToolCall: (name, input, result) {
      final status = result.success ? '✓' : '✗';
      print('  [$name] $status');
    },
  );

  // Restore previously registered dynamic tools.
  final restoredTools = await storage.loadTools();
  print('Restored ${restoredTools.length} dynamic tool(s) from registry.');
  for (final tool in restoredTools) {
    agent.registerTool(tool);
  }

  // Registry search — lets the LLM find existing tools before registering new ones.
  agent.registerTool(SearchToolsTool(storage));

  // Wire dynamic tool registration with persistence.
  agent.registerTool(
    RegisterToolTool(
      workspaceRoot,
      toolExists: (name) => _toolIsAvailable(agent, name),
      onRegister: (tool) {
        agent.registerTool(tool);
        if (tool is DynamicTool) {
          // Persist asynchronously — fire and forget in this example.
          storage.saveTool(tool).catchError((Object e) {
            stderr.writeln('Warning: failed to persist tool ${tool.name}: $e');
          });
        }
      },
    ),
  );

  // ── Task ──────────────────────────────────────────────────────────────────

  final task = isResuming
      ? 'Using the caesar_cipher tool you already registered, '
          'encrypt the message "HELLO WORLD" with shift 13.'
      : 'Create a tool called "caesar_cipher" that takes a "text" string '
          'and a "shift" integer and returns the Caesar-cipher-encrypted text. '
          'Then use it to encrypt "ENVOY WORKS" with shift 3.';

  print('\nTask: $task\n');
  final response = await agent.run(task);

  print('\nFinal response:');
  print(response);
  print('\nSession ID (pass to resume): $sessionId');
}
