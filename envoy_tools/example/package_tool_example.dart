// Package context demo: agent registers a tool that uses package:http.
//
// Dynamic tools can now import package:http and package:path in addition to
// dart: core libraries. The tool runner project at <workspace>/.envoy/ is
// initialized once by RegisterToolTool before the first registration.
//
// Run with: ANTHROPIC_API_KEY=<key> dart run example/package_tool_example.dart

import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';

// ── ANSI helpers (same as other examples) ─────────────────────────────────

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

// ── Observer ───────────────────────────────────────────────────────────────

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
      if (result.success) {
        print(_yellow('  input: $input'));
        _printBlock('  output', result.output, _dim);
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

  final workspaceRoot = Directory.systemTemp.createTempSync('envoy_pkg_').path;

  final agent = EnvoyAgent(
    EnvoyConfig(
      apiKey: apiKey,
      model: 'claude-haiku-4-5-20251001',
      maxTokens: 4096,
    ),
    tools: EnvoyTools.defaults(workspaceRoot),
    onToolCall: _onToolCall,
  );

  agent.registerTool(
    RegisterToolTool(workspaceRoot, onRegister: agent.registerTool),
  );

  // The task requires the agent to write a tool using package:http.
  // api.github.com/zen returns a single-line Zen of GitHub quote (no auth).
  const task =
      'Create a tool called "github_zen" that uses package:http to fetch '
      'a random Zen quote from https://api.github.com/zen (plain text response, '
      'no auth needed, no input parameters required). Then call the tool and '
      'tell me the quote.';

  print(_bold('Workspace: $workspaceRoot'));
  print(_bold('Task: $task'));
  print('');

  final response = await agent.run(task);

  _divider(_bold('FINAL RESPONSE'));
  print(response);
  print('');

  await Directory(workspaceRoot).delete(recursive: true);
}
