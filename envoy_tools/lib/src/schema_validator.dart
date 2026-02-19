import 'package:endorse/endorse.dart';
import 'package:envoy/envoy.dart';

/// Maps a JSON Schema [inputSchema] to Endorse validation rules and validates
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
      final isRequired = required.contains(fieldName);
      final value = input[fieldName];

      final validator = ValidateValue();
      if (isRequired) validator.isRequired();

      // Only add type rules when a value is present; Required() handles
      // the absent-but-required case above.
      if (value != null) {
        switch (fieldSchema['type'] as String?) {
          case 'string':
            validator.isString();
          case 'integer':
            validator.isInt();
          case 'number':
            validator.isNum();
          case 'boolean':
            validator.isBoolean();
          case 'array':
            validator.isList();
          case 'object':
            validator.isMap();
        }
      }

      final result = validator.from(value, fieldName);
      if (result.$isNotValid) {
        errors.addAll(result.$errors.map((e) => '  $fieldName: ${e.message}'));
      }
    }

    if (errors.isEmpty) return null;
    return ToolResult.err('Input validation failed:\n${errors.join('\n')}');
  }
}
