import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:path/path.dart' as p;

import 'dynamic_tool.dart';

/// Registers a new tool at runtime by writing and analyzing a Dart script.
///
/// When called, the agent supplies a complete Dart implementation. This tool:
/// 1. Writes the code to `<workspace>/.envoy/tools/<name>.dart`
/// 2. Runs `dart analyze` — errors block registration
/// 3. Creates a [DynamicTool] and calls [onRegister]
///
/// ## Dynamic tool contract
///
/// The script must use only `dart:` core libraries and implement:
/// - Read JSON input from `args[0]`
/// - Write `{"success": true, "output": "..."}` or
///   `{"success": false, "error": "..."}` to stdout
///
/// ```dart
/// import 'dart:convert';
///
/// void main(List<String> args) {
///   final input = jsonDecode(args[0]) as Map<String, dynamic>;
///   // ... do work ...
///   print(jsonEncode({'success': true, 'output': 'result'}));
/// }
/// ```
class RegisterToolTool extends Tool {
  final String workspaceRoot;

  /// Called with the newly created [DynamicTool] after successful registration.
  ///
  /// Pass `agent.registerTool` to wire this directly into the agent loop.
  final void Function(Tool) onRegister;

  RegisterToolTool(this.workspaceRoot, {required this.onRegister});

  @override
  String get name => 'register_tool';

  @override
  String get description =>
      'Register a new tool by supplying its Dart implementation. '
      'The code is analyzed with `dart analyze` before registration. '
      'Only dart: core libraries are available — no package: imports. '
      'Contract: read JSON input from args[0]; write '
      '{"success": true, "output": "..."} or {"success": false, "error": "..."} to stdout.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Unique snake_case identifier for the tool',
          },
          'description': {
            'type': 'string',
            'description': 'Natural language description of what the tool does',
          },
          'permission': {
            'type': 'string',
            'enum': [
              'compute',
              'readFile',
              'writeFile',
              'network',
              'process',
            ],
            'description': 'Permission tier required by the tool',
          },
          'inputSchema': {
            'type': 'object',
            'description':
                'JSON Schema object describing the tool\'s input parameters',
          },
          'code': {
            'type': 'string',
            'description':
                'Complete Dart source. Must import only dart: core libs. '
                'Read input from args[0] (JSON string); print JSON result to stdout.',
          },
        },
        'required': [
          'name',
          'description',
          'permission',
          'inputSchema',
          'code',
        ],
      };

  @override
  ToolPermission get permission => ToolPermission.process;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final name = input['name'] as String?;
    final description = input['description'] as String?;
    final permissionStr = input['permission'] as String?;
    final inputSchema = input['inputSchema'] as Map<String, dynamic>?;
    final code = input['code'] as String?;

    if (name == null || name.isEmpty) {
      return const ToolResult.err('name is required');
    }
    if (description == null || description.isEmpty) {
      return const ToolResult.err('description is required');
    }
    if (permissionStr == null) {
      return const ToolResult.err('permission is required');
    }
    if (inputSchema == null) {
      return const ToolResult.err('inputSchema is required');
    }
    if (code == null || code.isEmpty) {
      return const ToolResult.err('code is required');
    }

    final permission = _parsePermission(permissionStr);
    if (permission == null) {
      return ToolResult.err(
        'unknown permission "$permissionStr"; '
        'valid: compute, readFile, writeFile, network, process',
      );
    }

    // Write to <workspace>/.envoy/tools/<name>.dart
    final toolsDir = Directory(p.join(workspaceRoot, '.envoy', 'tools'));
    await toolsDir.create(recursive: true);
    final scriptFile = File(p.join(toolsDir.path, '$name.dart'));
    await scriptFile.writeAsString(code);

    // Analyze — errors block registration, warnings are accepted.
    final analyze = await Process.run('dart', ['analyze', scriptFile.path]);
    if (analyze.exitCode != 0) {
      await scriptFile.delete();
      final output = '${analyze.stdout}${analyze.stderr}'.trim();
      return ToolResult.err('dart analyze failed:\n$output');
    }

    // Register
    final tool = DynamicTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      permission: permission,
      scriptPath: scriptFile.path,
    );
    onRegister(tool);

    return ToolResult.ok('Tool "$name" registered at ${scriptFile.path}');
  }

  static ToolPermission? _parsePermission(String s) => switch (s) {
        'compute' => ToolPermission.compute,
        'readFile' => ToolPermission.readFile,
        'writeFile' => ToolPermission.writeFile,
        'network' => ToolPermission.network,
        'process' => ToolPermission.process,
        _ => null,
      };
}
