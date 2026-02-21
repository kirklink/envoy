// Simple interactive chat with a SOUL.md-driven personality.
//
// Loads a soul file as the system prompt and lets you chat.
// Run with: source ../.env && dart run example/soul_chat.dart [path/to/soul.md]

import 'dart:io';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

const _kReset = '\x1B[0m';
const _kDim = '\x1B[2m';
const _kCyan = '\x1B[36m';

String _dim(String s) => '$_kDim$s$_kReset';
String _cyan(String s) => '$_kCyan$s$_kReset';

Future<void> main(List<String> args) async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  // Load soul file.
  final soulPath = args.isNotEmpty
      ? args.first
      : '../envoy/.temp/soul_template.md';
  final soulFile = File(soulPath);
  if (!soulFile.existsSync()) {
    stderr.writeln('ERROR: Soul file not found: $soulPath');
    exit(1);
  }
  final soul = soulFile.readAsStringSync();

  print(_dim('Soul loaded from $soulPath (${soul.length} chars)'));
  print(_dim('Model: claude-haiku-4-5-20251001'));
  print(_dim('Type "quit" to exit.\n'));

  final client = anthropic.AnthropicClient(apiKey: apiKey);
  const model = 'claude-haiku-4-5-20251001';
  final messages = <anthropic.Message>[];
  var totalTokens = 0;

  while (true) {
    stdout.write('you> ');
    final input = stdin.readLineSync();
    if (input == null || input.trim().toLowerCase() == 'quit') break;
    if (input.trim().isEmpty) continue;

    messages.add(anthropic.Message(
      role: anthropic.MessageRole.user,
      content: anthropic.MessageContent.text(input),
    ));

    try {
      final response = await client.createMessage(
        request: anthropic.CreateMessageRequest(
          model: anthropic.Model.modelId(model),
          maxTokens: 2048,
          system: anthropic.CreateMessageRequestSystem.text(soul),
          messages: messages,
        ),
      );

      final usage = response.usage;
      final turnTokens =
          (usage?.inputTokens ?? 0) + (usage?.outputTokens ?? 0);
      totalTokens += turnTokens;

      final text = response.content.text;
      messages.add(anthropic.Message(
        role: anthropic.MessageRole.assistant,
        content: response.content,
      ));

      print('');
      print(_cyan(text));
      print(_dim('  ($turnTokens tokens, $totalTokens cumulative)\n'));
    } catch (e) {
      print('ERROR: $e\n');
    }
  }

  print(_dim('\nSession ended. $totalTokens total tokens.'));
}
