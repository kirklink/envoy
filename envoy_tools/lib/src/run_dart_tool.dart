import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:path/path.dart' as p;

import 'schema_validating_tool.dart';

/// Executes a Dart script as a subprocess.
///
/// Accepts either a path to an existing file or inline Dart code.
/// This is the primary mechanism for dynamic tool execution — the LLM
/// can write Dart code and execute it immediately.
///
/// Output is captured from stdout; stderr is appended on failure.
/// Execution is bounded by [timeout].
class RunDartTool extends Tool with SchemaValidatingTool {
  final String workspaceRoot;
  final Duration timeout;

  RunDartTool(
    this.workspaceRoot, {
    this.timeout = const Duration(seconds: 30),
  });

  @override
  String get name => 'run_dart';

  @override
  String get description =>
      'Execute a Dart script. Provide either "path" (relative to workspace root) '
      'or "code" (inline Dart source). Returns stdout on success, stderr on failure.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Path to an existing .dart file, relative to workspace root',
          },
          'code': {
            'type': 'string',
            'description': 'Inline Dart source code to execute',
          },
          'args': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Command-line arguments passed to the script',
          },
        },
      };

  @override
  ToolPermission get permission => ToolPermission.process;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final codePath = input['path'] as String?;
    final inlineCode = input['code'] as String?;
    final args = (input['args'] as List<dynamic>?)?.cast<String>() ?? [];

    if (codePath == null && inlineCode == null) {
      return const ToolResult.err('either "path" or "code" is required');
    }
    if (codePath != null && inlineCode != null) {
      return const ToolResult.err('"path" and "code" are mutually exclusive');
    }

    String scriptPath;
    File? tempFile;

    if (inlineCode != null) {
      // Write inline code to a temp file.
      tempFile = File(p.join(Directory.systemTemp.path,
          'envoy_run_${DateTime.now().millisecondsSinceEpoch}.dart'));
      await tempFile.writeAsString(inlineCode);
      scriptPath = tempFile.path;
    } else {
      final resolved = _resolve(codePath!);
      if (resolved == null) {
        return const ToolResult.err('path escapes workspace root');
      }
      scriptPath = resolved;
    }

    try {
      final result = await Process.run(
        'dart',
        ['run', scriptPath, ...args],
        workingDirectory: workspaceRoot,
      ).timeout(timeout, onTimeout: () async {
        return ProcessResult(-1, -1, '', 'process timed out after ${timeout.inSeconds}s');
      });

      if (result.exitCode == 0) {
        final stdout = (result.stdout as String).trim();
        return ToolResult.ok(stdout.isEmpty ? '(no output)' : stdout);
      } else {
        final stderr = (result.stderr as String).trim();
        final stdout = (result.stdout as String).trim();
        final output = [
          if (stdout.isNotEmpty) 'stdout: $stdout',
          if (stderr.isNotEmpty) 'stderr: $stderr',
        ].join('\n');
        return ToolResult.err(
          'exit code ${result.exitCode}\n$output',
        );
      }
    } catch (e) {
      return ToolResult.err('execution failed: $e');
    } finally {
      await tempFile?.delete().catchError((Object _) => tempFile!);
    }
  }

  String? _resolve(String relativePath) {
    final root = p.normalize(p.absolute(workspaceRoot));
    final resolved = p.normalize(p.join(root, relativePath));
    return resolved.startsWith(root) ? resolved : null;
  }
}
