// Visibility demo: watch every tool call the agent makes in real time.
//
// The agent is given the same task as tools_example.dart (write + run a Dart
// script), but this time every tool invocation is printed to the console as it
// happens — so you can see the code the LLM writes and the output it produces.
//
// Run with: ANTHROPIC_API_KEY=<key> dart run example/watch_example.dart

import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';

// ── ANSI colour helpers ────────────────────────────────────────────────────

const _kReset = '\x1B[0m';
const _kBold = '\x1B[1m';
const _kDim = '\x1B[2m';
const _kCyan = '\x1B[36m';
const _kGreen = '\x1B[32m';
const _kRed = '\x1B[31m';
const _kYellow = '\x1B[33m';

String _bold(String s) => '$_kBold$s$_kReset';
String _dim(String s) => '$_kDim$s$_kReset';
String _cyan(String s) => '$_kCyan$s$_kReset';
String _green(String s) => '$_kGreen$s$_kReset';
String _red(String s) => '$_kRed$s$_kReset';
String _yellow(String s) => '$_kYellow$s$_kReset';

// ── Layout helpers ─────────────────────────────────────────────────────────

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
    case 'write_file':
      final path = input['path'] as String? ?? '?';
      final content = input['content'] as String? ?? '';
      print(_yellow('  path: $path'));
      _printBlock('  code', content, _green);

    case 'run_dart':
      if (input.containsKey('path')) {
        print(_yellow('  file: ${input['path']}'));
      } else {
        _printBlock('  code', input['code'] as String? ?? '', _green);
      }
      if (result.success) {
        _printBlock('  stdout', result.output, _dim);
      } else {
        _printBlock('  error', result.error ?? '', _red);
      }

    case 'read_file':
      print(_yellow('  path: ${input['path']}'));
      if (result.success) {
        _printBlock('  content', result.output, _dim);
      } else {
        print(_red('  error: ${result.error}'));
      }

    case 'fetch_url':
      print(_yellow('  url: ${input['url']}'));
      if (!result.success) {
        print(_red('  error: ${result.error}'));
      } else {
        print(_dim('  ${result.output.length} bytes'));
      }

    default:
      print(_yellow('  input: $input'));
      if (!result.success) print(_red('  error: ${result.error}'));
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

  final workspaceRoot = Directory.systemTemp.createTempSync('envoy_watch_').path;

  final agent = EnvoyAgent(
    EnvoyConfig(
      apiKey: apiKey,
      model: 'claude-haiku-4-5-20251001',
      maxTokens: 2048,
    ),
    tools: EnvoyTools.defaults(workspaceRoot),
    onToolCall: _onToolCall,
  );

  const task =
      'Write a Dart script to hello.dart that prints "Phase 2 complete", '
      'then run it and tell me what it printed.';

  print(_bold('Workspace: $workspaceRoot'));
  print(_bold('Task: $task'));
  print('');

  final response = await agent.run(task);

  _divider(_bold('FINAL RESPONSE'));
  print(response);
  print('');

  await Directory(workspaceRoot).delete(recursive: true);
}
