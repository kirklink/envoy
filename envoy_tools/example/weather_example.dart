// Weather demo: give the agent a real-world task and watch it figure it out.
//
// The agent has fetch_url, run_dart, register_tool, and ask_user.
// It decides how to approach the problem — no hand-holding.
//
// Run with: source ../.env && dart run example/weather_example.dart

import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final workspaceRoot =
      Directory.systemTemp.createTempSync('envoy_weather_').path;

  final agent = EnvoyAgent(
    EnvoyConfig(
      apiKey: apiKey,
      model: 'claude-haiku-4-5-20251001',
      maxTokens: 8192,
      maxIterations: 15,
    ),
    tools: EnvoyTools.defaults(
      workspaceRoot,
      onAskUser: (question) async {
        stdout.writeln('\n🤖 Agent asks: $question');
        stdout.write('> ');
        return stdin.readLineSync() ?? '';
      },
    ),
    onToolCall: (name, input, result) {
      final status = result.success ? '✓' : '✗';
      final detail = name == 'fetch_url'
          ? '${input['url']}'
          : name == 'register_tool'
              ? '${input['name']}'
              : '';
      print('  [$name] $status $detail');
    },
  );

  // Wire dynamic tool registration so the agent can build tools if it wants.
  agent.registerTool(
    RegisterToolTool(workspaceRoot, onRegister: agent.registerTool),
  );

  const task =
      'Get me the current weather conditions in Toronto, Ontario, Canada '
      'using the Environment Canada weather API. '
      'Tell me the temperature, conditions, and humidity.';

  print('Task: $task\n');

  final result = await agent.run(task);

  print('\n--- Response ---');
  print(result.response);
  print('\n--- Stats ---');
  print(result);
  for (final tc in result.toolCalls) {
    print('  $tc');
  }

  await Directory(workspaceRoot).delete(recursive: true);
}
