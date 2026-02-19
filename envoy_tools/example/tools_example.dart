// Phase 2 smoke test: agent with seed tools.
//
// The agent is given a task that requires writing a file and running it.
// Demonstrates the full loop: LLM → write_file → run_dart → text response.
//
// Run with: ANTHROPIC_API_KEY=<key> dart run example/tools_example.dart

import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final workspaceRoot = Directory.systemTemp.createTempSync('envoy_smoke_').path;

  final agent = EnvoyAgent(
    EnvoyConfig(
      apiKey: apiKey,
      model: 'claude-haiku-4-5-20251001',
      maxTokens: 2048,
    ),
    tools: EnvoyTools.defaults(workspaceRoot),
  );

  const task =
      'Write a Dart script to hello.dart that prints "Phase 2 complete", '
      'then run it and tell me what it printed.';

  print('Workspace: $workspaceRoot');
  print('Task: $task\n');
  final result = await agent.run(task);
  print('Response: ${result.response}');
  print(result);

  // Cleanup
  await Directory(workspaceRoot).delete(recursive: true);
}
