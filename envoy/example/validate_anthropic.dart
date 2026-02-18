// Phase 0 validation: anthropic_sdk_dart
//
// Run with: ANTHROPIC_API_KEY=<key> dart run example/validate_anthropic.dart
//
// Checks:
//   [1] Messages API round-trip
//   [2] Streaming
//   [3] Tool use / function calling

import 'dart:io';
import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart';

const model = 'claude-haiku-4-5-20251001';

void pass(String label) => print('  [PASS] $label');
void fail(String label, Object e) {
  print('  [FAIL] $label: $e');
  exit(1);
}

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    print('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final client = AnthropicClient(apiKey: apiKey);

  // ── [1] Messages API ────────────────────────────────────────────────────────
  print('\n[1] Messages API round-trip');
  try {
    final res = await client.createMessage(
      request: CreateMessageRequest(
        model: Model.modelId(model),
        maxTokens: 64,
        messages: [
          Message(
            role: MessageRole.user,
            content: MessageContent.text('Reply with exactly: ok'),
          ),
        ],
      ),
    );
    final text = res.content.text;
    if (text.isEmpty) throw Exception('empty response');
    pass('received: "$text"');
  } catch (e) {
    fail('messages API', e);
  }

  // ── [2] Streaming ────────────────────────────────────────────────────────────
  print('\n[2] Streaming');
  try {
    final buffer = StringBuffer();
    var deltaCount = 0;

    final stream = client.createMessageStream(
      request: CreateMessageRequest(
        model: Model.modelId(model),
        maxTokens: 64,
        messages: [
          Message(
            role: MessageRole.user,
            content: MessageContent.text('Count to 3, one word per line.'),
          ),
        ],
      ),
    );

    await for (final event in stream) {
      event.mapOrNull(
        contentBlockDelta: (e) {
          final text = e.delta.text;
          if (text.isNotEmpty) {
            buffer.write(text);
            deltaCount++;
          }
        },
      );
    }

    if (deltaCount == 0) throw Exception('no delta events received');
    pass('received $deltaCount delta events, content: "${buffer.toString().trim()}"');
  } catch (e) {
    fail('streaming', e);
  }

  // ── [3] Tool use ─────────────────────────────────────────────────────────────
  print('\n[3] Tool use / function calling');
  try {
    final echoTool = Tool.custom(
      name: 'echo',
      description: 'Echoes the input text back.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': 'Text to echo'},
        },
        'required': ['text'],
      },
    );

    final res = await client.createMessage(
      request: CreateMessageRequest(
        model: Model.modelId(model),
        maxTokens: 128,
        tools: [echoTool],
        toolChoice: ToolChoice(
          type: ToolChoiceType.tool,
          name: 'echo',
        ),
        messages: [
          Message(
            role: MessageRole.user,
            content: MessageContent.text('Echo the word: validation'),
          ),
        ],
      ),
    );

    final toolUse = res.content.blocks
        .map((b) => b.toolUse)
        .nonNulls
        .firstOrNull;
    if (toolUse == null) throw Exception('no tool use block in response');
    if (toolUse.input['text'] == null) {
      throw Exception('tool input missing "text" field');
    }
    pass('tool called: ${toolUse.name}(text: "${toolUse.input['text']}")');
  } catch (e) {
    fail('tool use', e);
  }

  print('\nAll checks passed. anthropic_sdk_dart is viable for Phase 0.\n');
}
