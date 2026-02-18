import 'package:envoy/envoy.dart';

import 'fetch_url_tool.dart';
import 'read_file_tool.dart';
import 'run_dart_tool.dart';
import 'write_file_tool.dart';

/// Convenience factory for the standard seed tool set.
class EnvoyTools {
  /// Returns all four seed tools scoped to [workspaceRoot].
  ///
  /// Pass this list directly to [EnvoyAgent]:
  /// ```dart
  /// final agent = EnvoyAgent(config, tools: EnvoyTools.defaults('/my/project'));
  /// ```
  static List<Tool> defaults(
    String workspaceRoot, {
    Duration runDartTimeout = const Duration(seconds: 30),
  }) =>
      [
        ReadFileTool(workspaceRoot),
        WriteFileTool(workspaceRoot),
        FetchUrlTool(),
        RunDartTool(workspaceRoot, timeout: runDartTimeout),
      ];
}
