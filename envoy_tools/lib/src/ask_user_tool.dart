import 'dart:async';

import 'package:envoy/envoy.dart';

import 'schema_validating_tool.dart';

/// Called when the agent needs to ask the user a question.
///
/// Receives the [question] string and returns the user's answer.
/// The implementation depends on the interaction model: CLI reads from stdin,
/// HTTP waits for a response, etc.
typedef OnAskUser = Future<String> Function(String question);

/// Lets the agent ask the user a question when it needs help.
///
/// Use this when the agent lacks information, needs clarification, or is stuck
/// after trying multiple approaches. The actual I/O is handled by the
/// [OnAskUser] callback injected at construction — the tool itself is
/// interaction-model agnostic.
///
/// ## Example (CLI)
///
/// ```dart
/// AskUserTool(onAskUser: (question) async {
///   stdout.writeln(question);
///   stdout.write('> ');
///   return stdin.readLineSync() ?? '';
/// })
/// ```
class AskUserTool extends Tool with SchemaValidatingTool {
  final OnAskUser _onAskUser;

  AskUserTool({required OnAskUser onAskUser}) : _onAskUser = onAskUser;

  @override
  String get name => 'ask_user';

  @override
  String get description =>
      'Ask the user a question. Use this when you need more information, '
      'clarification, or are stuck and cannot proceed without human input. '
      'The user will see your question and type a response.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'question': {
            'type': 'string',
            'description': 'The question to ask the user',
          },
        },
        'required': ['question'],
      };

  @override
  ToolPermission get permission => ToolPermission.compute;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final question = input['question'] as String?;
    if (question == null || question.isEmpty) {
      return const ToolResult.err('question is required');
    }

    try {
      final answer = await _onAskUser(question);
      if (answer.isEmpty) {
        return const ToolResult.ok('(The user provided no response.)');
      }
      return ToolResult.ok(answer);
    } catch (e) {
      return ToolResult.err('failed to get user input: $e');
    }
  }
}
