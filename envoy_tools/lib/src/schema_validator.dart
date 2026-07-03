import 'package:envoy/envoy.dart';

/// Maps a JSON Schema [inputSchema] to validation rules and validates
/// [input] against them.
///
/// Supports the subset of JSON Schema used in tool definitions:
/// - `required` array (presence check)
/// - `type`: `string`, `integer`, `number`, `boolean`, `array`, `object`
///
/// Returns `null` if all fields are valid, or a [ToolResult.err] describing
/// every validation failure if any field is invalid.
class SchemaValidator {
  static ToolResult? validate(
    Map<String, dynamic> input,
    Map<String, dynamic> schema,
  ) {
    final properties = schema['properties'] as Map<String, dynamic>? ?? {};
    if (properties.isEmpty) return null;

    final required =
        (schema['required'] as List<dynamic>? ?? []).cast<String>().toSet();

    final errors = <String>[];

    for (final entry in properties.entries) {
      final fieldName = entry.key;
      final fieldSchema = entry.value as Map<String, dynamic>? ?? {};
      final value = input[fieldName];

      if (value == null) {
        if (required.contains(fieldName)) {
          errors.add('  $fieldName: is required');
        }
        continue;
      }

      final expectedType = fieldSchema['type'] as String?;
      final typeError = _checkType(value, expectedType);
      if (typeError != null) {
        errors.add('  $fieldName: $typeError');
      }
    }

    if (errors.isEmpty) return null;
    return ToolResult.err('Input validation failed:\n${errors.join('\n')}');
  }

  /// Returns an error message if [value] does not match [expectedType],
  /// or `null` if it does (or the type is unrecognized/unspecified).
  static String? _checkType(dynamic value, String? expectedType) {
    switch (expectedType) {
      case 'string':
        return value is String ? null : 'must be a string';
      case 'integer':
        return value is int ? null : 'must be an integer';
      case 'number':
        return value is num ? null : 'must be a number';
      case 'boolean':
        return value is bool ? null : 'must be a boolean';
      case 'array':
        return value is List ? null : 'must be an array';
      case 'object':
        return value is Map ? null : 'must be an object';
      default:
        return null;
    }
  }
}
