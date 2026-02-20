import 'package:envoy/envoy.dart';

import 'ask_user_tool.dart';
import 'fetch_url_tool.dart';
import 'read_file_tool.dart';
import 'run_dart_tool.dart';
import 'write_file_tool.dart';

/// Convenience factory for the standard seed tool set.
class EnvoyTools {
  /// Returns the seed tools scoped to [workspaceRoot].
  ///
  /// When [onAskUser] is provided, includes [AskUserTool] so the agent can
  /// request human input when stuck or needing clarification.
  ///
  /// ```dart
  /// final agent = EnvoyAgent(config, tools: EnvoyTools.defaults(
  ///   '/my/project',
  ///   onAskUser: (q) async { stdout.writeln(q); return stdin.readLineSync()!; },
  /// ));
  /// ```
  static List<Tool> defaults(
    String workspaceRoot, {
    Duration runDartTimeout = const Duration(seconds: 30),
    int fetchMaxResponseLength = FetchUrlTool.defaultMaxResponseLength,
    OnAskUser? onAskUser,
  }) =>
      [
        ReadFileTool(workspaceRoot),
        WriteFileTool(workspaceRoot),
        FetchUrlTool(maxResponseLength: fetchMaxResponseLength),
        RunDartTool(workspaceRoot, timeout: runDartTimeout),
        if (onAskUser != null) AskUserTool(onAskUser: onAskUser),
      ];
}
