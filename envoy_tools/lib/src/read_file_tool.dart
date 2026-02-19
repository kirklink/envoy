import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:path/path.dart' as p;

import 'schema_validating_tool.dart';

/// Reads the contents of a file within the workspace.
///
/// Path traversal outside [workspaceRoot] is rejected.
class ReadFileTool extends Tool with SchemaValidatingTool {
  final String workspaceRoot;

  ReadFileTool(this.workspaceRoot);

  @override
  String get name => 'read_file';

  @override
  String get description =>
      'Read the contents of a file. Path must be relative to the workspace root.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'File path relative to workspace root',
          },
        },
        'required': ['path'],
      };

  @override
  ToolPermission get permission => ToolPermission.readFile;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final relativePath = input['path'] as String?;
    if (relativePath == null || relativePath.isEmpty) {
      return const ToolResult.err('path is required');
    }

    final resolved = _resolve(relativePath);
    if (resolved == null) {
      return const ToolResult.err('path escapes workspace root');
    }

    try {
      final content = await File(resolved).readAsString();
      return ToolResult.ok(content);
    } on FileSystemException catch (e) {
      return ToolResult.err('could not read file: ${e.message}');
    }
  }

  String? _resolve(String relativePath) {
    final root = p.normalize(p.absolute(workspaceRoot));
    final resolved = p.normalize(p.join(root, relativePath));
    return resolved.startsWith(root) ? resolved : null;
  }
}
