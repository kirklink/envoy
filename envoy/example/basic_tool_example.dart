// Basic example: an agent with a single custom tool.
//
// Demonstrates:
//   - Implementing the Tool interface
//   - Registering tools with EnvoyAgent
//   - The LLM calling a tool to answer a question it can't answer alone
//
// Run with: ANTHROPIC_API_KEY=<key> dart run example/basic_tool_example.dart

import 'dart:io';

import 'package:envoy/envoy.dart';

// A tool that returns the current date and time.
// The LLM doesn't know the current time, so it must call this tool.
class CurrentTimeTool extends Tool {
  @override
  String get name => 'get_current_time';

  @override
  String get description =>
      'Returns the current date and time in ISO 8601 format.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  ToolPermission get permission => ToolPermission.compute;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    return ToolResult.ok(DateTime.now().toIso8601String());
  }
}

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final agent = EnvoyAgent(
    EnvoyConfig(
      apiKey: apiKey,
      model: 'claude-haiku-4-5-20251001',
      maxTokens: 1024,
    ),
    tools: [CurrentTimeTool()],
  );

  print('Task: What day of the week is it today?\n');
  final result = await agent.run('What day of the week is it today?');
  print('Response: $result');
}
