import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:envoy/envoy.dart';

/// A [Tool] backed by a Dart script file executed as a subprocess.
///
/// Dynamic tools are registered at runtime by [RegisterToolTool]. The script
/// must implement the dynamic-tool I/O contract:
///
/// - Receive JSON-encoded input as `args[0]`
/// - Write `{"success": true, "output": "..."}` or
///   `{"success": false, "error": "..."}` to stdout
///
/// Only `dart:` core libraries are available to dynamic tool scripts — they
/// run outside any package context.
class DynamicTool extends Tool {
  final String _name;
  final String _description;
  final Map<String, dynamic> _inputSchema;
  final ToolPermission _permission;

  /// Absolute path to the Dart script implementing this tool.
  final String scriptPath;

  final Duration timeout;

  DynamicTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required ToolPermission permission,
    required this.scriptPath,
    this.timeout = const Duration(seconds: 30),
  })  : _name = name,
        _description = description,
        _inputSchema = inputSchema,
        _permission = permission;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  Map<String, dynamic> get inputSchema => _inputSchema;

  @override
  ToolPermission get permission => _permission;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'dart',
        ['run', scriptPath, jsonEncode(input)],
      ).timeout(timeout);
    } on TimeoutException {
      return const ToolResult.err('tool execution timed out');
    } catch (e) {
      return ToolResult.err('failed to start process: $e');
    }

    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      final stdout = (result.stdout as String).trim();
      final detail = [
        if (stdout.isNotEmpty) 'stdout: $stdout',
        if (stderr.isNotEmpty) 'stderr: $stderr',
      ].join('\n');
      return ToolResult.err('exit ${result.exitCode}\n$detail');
    }

    final stdout = (result.stdout as String).trim();
    if (stdout.isEmpty) {
      return const ToolResult.err('tool produced no output');
    }

    try {
      final decoded = jsonDecode(stdout) as Map<String, dynamic>;
      if (decoded['success'] == true) {
        return ToolResult.ok(decoded['output'] as String? ?? '');
      }
      return ToolResult.err(
        decoded['error'] as String? ?? 'tool returned failure',
      );
    } catch (_) {
      return ToolResult.err('invalid tool output (expected JSON): $stdout');
    }
  }
}
