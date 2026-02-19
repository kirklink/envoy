import 'dart:async';
import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:path/path.dart' as p;

import 'dynamic_tool.dart';
import 'schema_validating_tool.dart';
import 'tool_runner.dart';

/// Called after `dart analyze` passes, before the tool is registered.
///
/// Receives the tool [name], its declared [permission], and the analyzed
/// [code]. Return `true` to allow registration, `false` to block it.
///
/// Use this as a human-in-the-loop approval gate: show the code, prompt
/// for confirmation, and return the user's decision.
typedef OnToolRegister = FutureOr<bool> Function(
  String name,
  ToolPermission permission,
  String code,
);

/// Registers a new tool at runtime by writing and analyzing a Dart script.
///
/// When called, the agent supplies a complete Dart implementation. This tool:
/// 1. Initializes the per-tier runner project (idempotent — runs once per tier)
/// 2. Writes the code to `<workspace>/.envoy/runners/<tier>/tools/<name>.dart`
/// 3. Runs `dart analyze` — errors block registration, warnings pass
/// 4. Calls [onToolRegister] if set — returning `false` blocks registration
/// 5. Creates a [DynamicTool] and calls [onRegister]
///
/// ## Package grants by permission tier
///
/// | Tier        | Available packages      |
/// |-------------|-------------------------|
/// | compute     | dart: core only         |
/// | readFile    | + package:path          |
/// | writeFile   | + package:path          |
/// | network     | + package:http + path   |
/// | process     | + package:http + path   |
///
/// ## Dynamic tool I/O contract
///
/// - Read JSON input from `args[0]`
/// - Print `{"success": true, "output": "..."}` or
///   `{"success": false, "error": "..."}` to stdout
/// - `main()` may be `async`
class RegisterToolTool extends Tool with SchemaValidatingTool {
  final String workspaceRoot;

  /// Called with the newly created [DynamicTool] after successful registration.
  ///
  /// Pass `agent.registerTool` to wire this directly into the agent loop.
  final void Function(Tool) onRegister;

  /// Optional human-in-the-loop review gate.
  ///
  /// Called after `dart analyze` passes, before the tool is registered.
  /// Return `true` to allow, `false` to block. If null, all analyzed tools
  /// are registered automatically.
  final OnToolRegister? onToolRegister;

  /// Optional lookup to prevent duplicate registrations.
  ///
  /// If provided, called with the requested tool name before any file I/O.
  /// When it returns `true`, registration is skipped with an informative
  /// message so the LLM uses the already-registered tool instead.
  ///
  /// Pass `agent.hasTool` to wire this automatically.
  final bool Function(String name)? toolExists;

  RegisterToolTool(
    this.workspaceRoot, {
    required this.onRegister,
    this.onToolRegister,
    this.toolExists,
  });

  @override
  String get name => 'register_tool';

  @override
  String get description =>
      'Register a new tool by supplying its Dart implementation. '
      'The code is analyzed with `dart analyze` before registration. '
      'Available packages depend on the declared permission tier: '
      'compute=dart:core only; readFile/writeFile=+package:path; '
      'network/process=+package:http+path. '
      'Contract: read JSON input from args[0]; print '
      '{"success": true, "output": "..."} or {"success": false, "error": "..."} to stdout. '
      'main() may be async.';

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
            'description':
                'Permission tier. Determines available packages: '
                'compute=dart:core; readFile/writeFile=+path; network/process=+http+path.',
          },
          'inputSchema': {
            'type': 'object',
            'description':
                'JSON Schema object describing the tool\'s input parameters',
          },
          'code': {
            'type': 'string',
            'description':
                'Complete Dart source. May use dart: core libs and packages '
                'allowed by the declared permission tier. '
                'Read input from args[0] (JSON string); print JSON result to stdout. '
                'main() may be async.',
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

    // Deduplication: skip registration if the tool is already available.
    if (toolExists != null && toolExists!(name)) {
      return ToolResult.ok(
        'Tool "$name" is already registered and ready to use. '
        'Call it directly instead of re-registering.',
      );
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

    // Initialize the tier-appropriate runner project (idempotent).
    final runnerError = await ToolRunner.ensure(workspaceRoot, permission);
    if (runnerError != null) {
      return ToolResult.err('runner init failed: $runnerError');
    }

    // Write to the tier-specific tools directory.
    final toolsDir = Directory(ToolRunner.toolsDir(workspaceRoot, permission));
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

    // Human-in-the-loop review gate (optional).
    if (onToolRegister != null) {
      final allowed = await onToolRegister!(name, permission, code);
      if (!allowed) {
        await scriptFile.delete();
        return ToolResult.err('Tool "$name" registration blocked by review gate.');
      }
    }

    // Register.
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
