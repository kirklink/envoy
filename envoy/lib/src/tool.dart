/// Permission tier required by a tool.
///
/// Tiers are declared by the tool and enforced by the runner at execution time.
/// Generated code is never trusted to self-limit.
enum ToolPermission {
  /// Pure computation only. Always granted.
  compute,

  /// Filesystem read, scoped to workspace root.
  readFile,

  /// Filesystem write, scoped to workspace root.
  writeFile,

  /// Network access (allowlist enforcement deferred to Phase 3).
  network,

  /// Process spawning via dart subprocess.
  process,
}

/// The result of executing a tool.
class ToolResult {
  /// Whether the tool execution succeeded.
  final bool success;

  /// JSON string or plain text output returned to the LLM.
  final String output;

  /// Error message, populated only when [success] is false.
  final String? error;

  /// Creates a successful result with the given [output] text.
  const ToolResult.ok(this.output)
      : success = true,
        error = null;

  /// Creates a failed result with the given [error] message.
  const ToolResult.err(String this.error)
      : success = false,
        output = '';
}

/// The atomic unit of capability in Envoy.
///
/// Implement this to register a tool with [EnvoyAgent]. Tools are either
/// static (shipped in envoy_tools) or dynamic (written by the LLM at runtime).
abstract class Tool {
  /// Unique identifier used by the LLM to invoke this tool.
  String get name;

  /// Natural language description surfaced to the LLM.
  String get description;

  /// JSON Schema describing the tool's input. Used for LLM tool calling
  /// and validated by Endorse at execution time (Phase 2).
  Map<String, dynamic> get inputSchema;

  /// Permission tier required by this tool.
  ToolPermission get permission;

  /// Validates [input] before [execute] is called.
  ///
  /// Return `null` if the input is valid; return [ToolResult.err] to
  /// short-circuit execution and surface the error to the LLM.
  ///
  /// The default implementation does no validation. Override — or mix in
  /// `SchemaValidatingTool` from `envoy_tools` — to add Endorse-backed
  /// JSON Schema validation.
  Future<ToolResult?> validateInput(Map<String, dynamic> input) async => null;

  /// Execute the tool with the given [input] map.
  Future<ToolResult> execute(Map<String, dynamic> input);
}
