import 'package:envoy/envoy.dart';

import 'schema_validator.dart';

/// Mixin that adds JSON Schema validation to any [Tool].
///
/// Override [validateInput] is provided automatically: it maps the tool's
/// declared [Tool.inputSchema] to validation rules and validates the incoming
/// [input] map before [Tool.execute] is called.
///
/// Usage:
/// ```dart
/// class MyTool extends Tool with SchemaValidatingTool { ... }
/// ```
mixin SchemaValidatingTool on Tool {
  @override
  Future<ToolResult?> validateInput(Map<String, dynamic> input) async =>
      SchemaValidator.validate(input, inputSchema);
}
