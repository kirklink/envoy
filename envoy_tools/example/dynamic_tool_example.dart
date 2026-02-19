// Phase 3a demo: agent registers and uses a tool it doesn't start with.
//
// The agent is given a task that requires a tool that isn't in the seed set.
// It calls register_tool, writes a Dart implementation, and then immediately
// uses the newly registered tool — all within a single agent.run() call.
//
// Run with: ANTHROPIC_API_KEY=<key> dart run example/dynamic_tool_example.dart

import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';

// ── ANSI colour helpers (same as watch_example) ────────────────────────────

const _kReset = '\x1B[0m';
const _kBold = '\x1B[1m';
const _kDim = '\x1B[2m';
const _kCyan = '\x1B[36m';
const _kGreen = '\x1B[32m';
const _kRed = '\x1B[31m';
const _kYellow = '\x1B[33m';
const _kMagenta = '\x1B[35m';

String _bold(String s) => '$_kBold$s$_kReset';
String _dim(String s) => '$_kDim$s$_kReset';
String _cyan(String s) => '$_kCyan$s$_kReset';
String _green(String s) => '$_kGreen$s$_kReset';
String _red(String s) => '$_kRed$s$_kReset';
String _yellow(String s) => '$_kYellow$s$_kReset';
String _magenta(String s) => '$_kMagenta$s$_kReset';

void _divider(String label) {
  const width = 60;
  final pad = width - label.length - 4;
  final left = pad ~/ 2;
  final right = pad - left;
  print(_cyan('${'─' * left} $label ${'─' * right}'));
}

void _printBlock(String label, String content, String Function(String) color) {
  print(_dim('$label:'));
  for (final line in content.trimRight().split('\n')) {
    print('  ${color(line)}');
  }
}

// ── Tool-call observer ─────────────────────────────────────────────────────

void _onToolCall(String name, Map<String, dynamic> input, ToolResult result) {
  _divider(_bold('TOOL: $name'));

  switch (name) {
    case 'register_tool':
      print(_magenta('  registering: ${input['name']}'));
      _printBlock('  code', input['code'] as String? ?? '', _green);
      if (result.success) {
        print(_dim('  ✓ ${result.output}'));
      } else {
        print(_red('  ✗ ${result.error}'));
      }

    default:
      // For any dynamically registered tool, show its name and I/O
      if (result.success) {
        print(_yellow('  input: $input'));
        print(_dim('  output: ${result.output}'));
      } else {
        print(_yellow('  input: $input'));
        print(_red('  error: ${result.error}'));
      }
  }

  print('');
}

// ── Main ───────────────────────────────────────────────────────────────────

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final workspaceRoot = Directory.systemTemp.createTempSync('envoy_dyn_').path;

  // Seed the agent with the four standard tools only.
  final agent = EnvoyAgent(
    EnvoyConfig(
      apiKey: apiKey,
      model: 'claude-haiku-4-5-20251001',
      maxTokens: 4096,
    ),
    tools: EnvoyTools.defaults(workspaceRoot),
    onToolCall: _onToolCall,
  );

  // Wire up register_tool — the agent can now extend itself.
  agent.registerTool(
    RegisterToolTool(workspaceRoot, onRegister: agent.registerTool),
  );

  const task =
      'I need you to create a tool called "caesar_cipher" that performs a '
      'Caesar cipher shift on a string. It should accept "text" (string) and '
      '"shift" (integer) as inputs. Once registered, use it to encode the '
      'message "Hello Envoy" with a shift of 13.';

  print(_bold('Workspace: $workspaceRoot'));
  print(_bold('Task: $task'));
  print('');

  final result = await agent.run(task);

  _divider(_bold('FINAL RESPONSE'));
  print(result.response);
  print('');
  print(_dim('$result'));
  print('');

  await Directory(workspaceRoot).delete(recursive: true);
}
