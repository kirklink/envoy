import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:path/path.dart' as p;

import 'schema_validating_tool.dart';

/// Writes content to a file within the workspace.
///
/// Creates parent directories if they don't exist.
/// Path traversal outside [workspaceRoot] is rejected.
class WriteFileTool extends Tool with SchemaValidatingTool {
  final String workspaceRoot;

  WriteFileTool(this.workspaceRoot);

  @override
  String get name => 'write_file';

  @override
  String get description =>
      'Write content to a file. Path must be relative to the workspace root. '
      'Creates parent directories as needed. Overwrites existing files.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'File path relative to workspace root',
          },
          'content': {
            'type': 'string',
            'description': 'Content to write to the file',
          },
        },
        'required': ['path', 'content'],
      };

  @override
  ToolPermission get permission => ToolPermission.writeFile;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final relativePath = input['path'] as String?;
    final content = input['content'] as String?;

    if (relativePath == null || relativePath.isEmpty) {
      return const ToolResult.err('path is required');
    }
    if (content == null) {
      return const ToolResult.err('content is required');
    }

    final resolved = _resolve(relativePath);
    if (resolved == null) {
      return const ToolResult.err('path escapes workspace root');
    }

    try {
      final file = File(resolved);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return ToolResult.ok('wrote ${content.length} bytes to $relativePath');
    } on FileSystemException catch (e) {
      return ToolResult.err('could not write file: ${e.message}');
    }
  }

  String? _resolve(String relativePath) {
    final root = p.normalize(p.absolute(workspaceRoot));
    final resolved = p.normalize(p.join(root, relativePath));
    return resolved.startsWith(root) ? resolved : null;
  }
}
