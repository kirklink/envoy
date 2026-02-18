import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('envoy_tools_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ── ReadFileTool ───────────────────────────────────────────────────────────

  group('ReadFileTool', () {
    test('reads an existing file', () async {
      final file = File(p.join(tempDir.path, 'hello.txt'));
      await file.writeAsString('hello world');

      final tool = ReadFileTool(tempDir.path);
      final result = await tool.execute({'path': 'hello.txt'});

      expect(result.success, isTrue);
      expect(result.output, 'hello world');
    });

    test('returns error for missing file', () async {
      final tool = ReadFileTool(tempDir.path);
      final result = await tool.execute({'path': 'nope.txt'});
      expect(result.success, isFalse);
    });

    test('rejects path traversal', () async {
      final tool = ReadFileTool(tempDir.path);
      final result = await tool.execute({'path': '../../etc/passwd'});
      expect(result.success, isFalse);
      expect(result.error, contains('escapes workspace'));
    });

    test('returns error when path is missing', () async {
      final tool = ReadFileTool(tempDir.path);
      final result = await tool.execute({});
      expect(result.success, isFalse);
    });

    test('has correct permission tier', () {
      expect(ReadFileTool('/').permission, ToolPermission.readFile);
    });
  });

  // ── WriteFileTool ──────────────────────────────────────────────────────────

  group('WriteFileTool', () {
    test('writes a file', () async {
      final tool = WriteFileTool(tempDir.path);
      final result = await tool.execute({
        'path': 'output.txt',
        'content': 'test content',
      });

      expect(result.success, isTrue);
      final written = await File(p.join(tempDir.path, 'output.txt')).readAsString();
      expect(written, 'test content');
    });

    test('creates parent directories', () async {
      final tool = WriteFileTool(tempDir.path);
      final result = await tool.execute({
        'path': 'a/b/c.txt',
        'content': 'nested',
      });

      expect(result.success, isTrue);
      final exists = await File(p.join(tempDir.path, 'a/b/c.txt')).exists();
      expect(exists, isTrue);
    });

    test('rejects path traversal', () async {
      final tool = WriteFileTool(tempDir.path);
      final result = await tool.execute({
        'path': '../../evil.txt',
        'content': 'bad',
      });
      expect(result.success, isFalse);
      expect(result.error, contains('escapes workspace'));
    });

    test('has correct permission tier', () {
      expect(WriteFileTool('/').permission, ToolPermission.writeFile);
    });
  });

  // ── RunDartTool ────────────────────────────────────────────────────────────

  group('RunDartTool', () {
    test('executes inline code and returns stdout', () async {
      final tool = RunDartTool(tempDir.path);
      final result = await tool.execute({
        'code': "void main() { print('dart works'); }",
      });

      expect(result.success, isTrue);
      expect(result.output, contains('dart works'));
    });

    test('returns error on non-zero exit', () async {
      final tool = RunDartTool(tempDir.path);
      final result = await tool.execute({
        'code': "void main() { throw Exception('boom'); }",
      });
      expect(result.success, isFalse);
    });

    test('rejects when neither path nor code is provided', () async {
      final tool = RunDartTool(tempDir.path);
      final result = await tool.execute({});
      expect(result.success, isFalse);
      expect(result.error, contains('either'));
    });

    test('rejects when both path and code are provided', () async {
      final tool = RunDartTool(tempDir.path);
      final result = await tool.execute({
        'path': 'foo.dart',
        'code': 'void main() {}',
      });
      expect(result.success, isFalse);
      expect(result.error, contains('mutually exclusive'));
    });

    test('has correct permission tier', () {
      expect(RunDartTool('/').permission, ToolPermission.process);
    });
  });

  // ── RegisterToolTool ───────────────────────────────────────────────────────

  group('RegisterToolTool', () {
    test('registers a valid tool and it becomes callable', () async {
      final registered = <Tool>[];
      final tool = RegisterToolTool(
        tempDir.path,
        onRegister: registered.add,
      );

      final result = await tool.execute({
        'name': 'reverse_string',
        'description': 'Reverses a string.',
        'permission': 'compute',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
          'required': ['text'],
        },
        'code': '''
import 'dart:convert';

void main(List<String> args) {
  final input = jsonDecode(args[0]) as Map<String, dynamic>;
  final text = input['text'] as String;
  final reversed = text.split('').reversed.join();
  print(jsonEncode({'success': true, 'output': reversed}));
}
''',
      });

      expect(result.success, isTrue, reason: result.error);
      expect(registered.length, 1);
      expect(registered.first.name, 'reverse_string');

      // Execute the registered tool
      final callResult = await registered.first.execute({'text': 'hello'});
      expect(callResult.success, isTrue);
      expect(callResult.output, 'olleh');
    });

    test('readFile-tier tool can use package:path', () async {
      final registered = <Tool>[];
      final tool = RegisterToolTool(tempDir.path, onRegister: registered.add);

      final result = await tool.execute({
        'name': 'join_paths',
        'description': 'Joins two path segments.',
        'permission': 'readFile', // readFile tier includes package:path
        'inputSchema': {
          'type': 'object',
          'properties': {
            'a': {'type': 'string'},
            'b': {'type': 'string'},
          },
          'required': ['a', 'b'],
        },
        'code': r"""
import 'dart:convert';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  final input = jsonDecode(args[0]) as Map<String, dynamic>;
  final joined = p.join(input['a'] as String, input['b'] as String);
  print(jsonEncode({'success': true, 'output': joined}));
}
""",
      });

      expect(result.success, isTrue, reason: result.error);
      final callResult = await registered.first.execute({'a': 'foo', 'b': 'bar.txt'});
      expect(callResult.success, isTrue);
      expect(callResult.output, contains('bar.txt'));
    });

    test('compute-tier tool cannot use package:path (tier enforcement)', () async {
      final tool = RegisterToolTool(tempDir.path, onRegister: (_) {});

      // package:path is not in the compute runner — dart analyze should reject it.
      final result = await tool.execute({
        'name': 'bad_compute_tool',
        'description': 'Tries to use package:path from compute tier.',
        'permission': 'compute',
        'inputSchema': {'type': 'object'},
        'code': r"""
import 'dart:convert';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  print(jsonEncode({'success': true, 'output': p.join('a', 'b')}));
}
""",
      });

      expect(result.success, isFalse,
          reason: 'compute tier should not have package:path');
    });

    test('onToolRegister callback can block registration', () async {
      final registered = <Tool>[];
      final tool = RegisterToolTool(
        tempDir.path,
        onRegister: registered.add,
        onToolRegister: (name, permission, code) => false, // always deny
      );

      final result = await tool.execute({
        'name': 'vetoed_tool',
        'description': 'This will be blocked.',
        'permission': 'compute',
        'inputSchema': {'type': 'object'},
        'code': "import 'dart:convert';\nvoid main(List<String> args) { print(jsonEncode({'success': true, 'output': 'ok'})); }",
      });

      expect(result.success, isFalse);
      expect(result.error, contains('blocked'));
      expect(registered, isEmpty);
    });

    test('onToolRegister callback can allow registration', () async {
      final reviewed = <String>[];
      final registered = <Tool>[];
      final tool = RegisterToolTool(
        tempDir.path,
        onRegister: registered.add,
        onToolRegister: (name, permission, code) {
          reviewed.add(name);
          return true; // approve
        },
      );

      final result = await tool.execute({
        'name': 'approved_tool',
        'description': 'This will be approved.',
        'permission': 'compute',
        'inputSchema': {'type': 'object'},
        'code': "import 'dart:convert';\nvoid main(List<String> args) { print(jsonEncode({'success': true, 'output': 'ok'})); }",
      });

      expect(result.success, isTrue, reason: result.error);
      expect(reviewed, contains('approved_tool'));
      expect(registered.length, 1);
    });

    test('rejects code that fails dart analyze', () async {
      final tool = RegisterToolTool(tempDir.path, onRegister: (_) {});

      final result = await tool.execute({
        'name': 'broken_tool',
        'description': 'This will fail analysis.',
        'permission': 'compute',
        'inputSchema': {'type': 'object'},
        'code': 'void main() { int x = "not an int"; }',
      });

      expect(result.success, isFalse);
      expect(result.error, contains('dart analyze'));
    });

    test('rejects unknown permission', () async {
      final tool = RegisterToolTool(tempDir.path, onRegister: (_) {});

      final result = await tool.execute({
        'name': 'bad',
        'description': 'test',
        'permission': 'superuser',
        'inputSchema': {'type': 'object'},
        'code': 'void main() {}',
      });

      expect(result.success, isFalse);
      expect(result.error, contains('unknown permission'));
    });

    test('has correct permission tier', () {
      expect(
        RegisterToolTool('/', onRegister: (_) {}).permission,
        ToolPermission.process,
      );
    });
  });

  // ── DynamicTool ────────────────────────────────────────────────────────────

  group('DynamicTool', () {
    test('executes a script and returns output', () async {
      final script = File(p.join(tempDir.path, 'echo_tool.dart'));
      await script.writeAsString('''
import 'dart:convert';

void main(List<String> args) {
  final input = jsonDecode(args[0]) as Map<String, dynamic>;
  print(jsonEncode({'success': true, 'output': 'got: \${input['msg']}'}));
}
''');

      final tool = DynamicTool(
        name: 'echo',
        description: 'echoes input',
        inputSchema: const {'type': 'object'},
        permission: ToolPermission.compute,
        scriptPath: script.path,
      );

      final result = await tool.execute({'msg': 'ping'});
      expect(result.success, isTrue);
      expect(result.output, 'got: ping');
    });

    test('returns error on non-zero exit', () async {
      final script = File(p.join(tempDir.path, 'fail_tool.dart'));
      await script.writeAsString('void main() { throw Exception("boom"); }');

      final tool = DynamicTool(
        name: 'fail',
        description: 'always fails',
        inputSchema: const {'type': 'object'},
        permission: ToolPermission.compute,
        scriptPath: script.path,
      );

      final result = await tool.execute({});
      expect(result.success, isFalse);
    });
  });

  // ── EnvoyTools factory ─────────────────────────────────────────────────────

  group('EnvoyTools', () {
    test('defaults returns four tools', () {
      final tools = EnvoyTools.defaults('/workspace');
      expect(tools.length, 4);
    });

    test('tool names are unique', () {
      final tools = EnvoyTools.defaults('/workspace');
      final names = tools.map((t) => t.name).toSet();
      expect(names.length, tools.length);
    });

    test('contains expected tool names', () {
      final names = EnvoyTools.defaults('/').map((t) => t.name).toSet();
      expect(names, containsAll(['read_file', 'write_file', 'fetch_url', 'run_dart']));
    });
  });
}
