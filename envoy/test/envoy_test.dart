import 'package:envoy/envoy.dart';
import 'package:test/test.dart';

// A minimal Tool implementation used across tests.
class _EchoTool extends Tool {
  @override
  String get name => 'echo';

  @override
  String get description => 'Echoes the input text.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      };

  @override
  ToolPermission get permission => ToolPermission.compute;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final text = input['text'] as String? ?? '';
    return ToolResult.ok(text);
  }
}

void main() {
  // ── Tool ───────────────────────────────────────────────────────────────────

  group('Tool', () {
    test('can be implemented and executed', () async {
      final tool = _EchoTool();
      final result = await tool.execute({'text': 'hello'});
      expect(result.success, isTrue);
      expect(result.output, 'hello');
      expect(result.error, isNull);
    });

    test('ToolResult.err sets success false', () {
      const result = ToolResult.err('something went wrong');
      expect(result.success, isFalse);
      expect(result.error, 'something went wrong');
      expect(result.output, isEmpty);
    });

    test('permission tier is declared on the tool', () {
      expect(_EchoTool().permission, ToolPermission.compute);
    });
  });

  // ── EnvoyContext ───────────────────────────────────────────────────────────

  group('EnvoyContext', () {
    test('starts empty', () {
      final ctx = EnvoyContext();
      expect(ctx.messages, isEmpty);
      expect(ctx.length, 0);
    });

    test('addUser appends a user message', () {
      final ctx = EnvoyContext();
      ctx.addUser('hello');
      expect(ctx.length, 1);
      expect(ctx.messages.first.role.name, 'user');
    });

    test('addToolResult appends a user message', () {
      final ctx = EnvoyContext();
      ctx.addUser('task');
      ctx.addToolResult('tool-id-1', '{"result": 42}');
      expect(ctx.length, 2);
      expect(ctx.messages.last.role.name, 'user');
    });

    test('messages list is unmodifiable', () {
      final ctx = EnvoyContext();
      ctx.addUser('hi');
      expect(
        () => ctx.messages.add(ctx.messages.first),
        throwsUnsupportedError,
      );
    });

    test('prunes oldest messages when token budget exceeded', () {
      // 10 tokens * 4 chars = 40 char budget, threshold at 80% = 32 chars.
      final ctx = EnvoyContext(maxTokens: 10);
      ctx.addUser('a' * 20);
      ctx.addUser('b' * 20);
      expect(ctx.length, lessThan(3));
    });

    test('estimatedTokens is positive after adding a message', () {
      final ctx = EnvoyContext();
      ctx.addUser('hello world');
      expect(ctx.estimatedTokens, greaterThan(0));
    });
  });

  // ── EnvoyConfig ────────────────────────────────────────────────────────────

  group('EnvoyConfig', () {
    test('defaults are set', () {
      const config = EnvoyConfig(apiKey: 'test');
      expect(config.model, 'claude-opus-4-6');
      expect(config.maxTokens, 8192);
      expect(config.maxIterations, 20);
    });

    test('values can be overridden', () {
      const config = EnvoyConfig(
        apiKey: 'test',
        model: 'claude-haiku-4-5-20251001',
        maxTokens: 4096,
        maxIterations: 5,
      );
      expect(config.model, 'claude-haiku-4-5-20251001');
      expect(config.maxTokens, 4096);
      expect(config.maxIterations, 5);
    });
  });
}
