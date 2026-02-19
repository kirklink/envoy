import 'package:envoy/envoy.dart';

import '../schema_validating_tool.dart';
import 'stanza_storage.dart';

/// Searches the persisted tool registry by capability description.
///
/// Use this before [RegisterToolTool] to check whether an existing tool
/// already covers the required capability. Returns matching tools with their
/// names, descriptions, and permission tiers so the LLM can call them
/// directly instead of writing new code.
///
/// ## Usage
///
/// ```dart
/// agent.registerTool(SearchToolsTool(storage));
/// ```
class SearchToolsTool extends Tool with SchemaValidatingTool {
  final StanzaEnvoyStorage _storage;

  SearchToolsTool(this._storage);

  @override
  String get name => 'search_tools';

  @override
  String get description =>
      'Search the tool registry for existing tools that match a capability. '
      'Always call this before register_tool — if a matching tool is found, '
      'load and use it directly instead of writing new code. '
      'Pass a natural-language description of the capability you need.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Natural-language description of the capability needed '
                '(e.g. "encrypt text with Caesar cipher")',
          },
        },
        'required': ['query'],
      };

  @override
  ToolPermission get permission => ToolPermission.network;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final query = input['query'] as String;

    final matches = await _storage.searchTools(query);

    if (matches.isEmpty) {
      return ToolResult.ok(
        'No tools found matching "$query". '
        'You may register a new tool with register_tool.',
      );
    }

    final buffer = StringBuffer(
      'Found ${matches.length} tool(s) matching "$query":\n\n',
    );
    for (final tool in matches) {
      buffer.writeln(
        '- ${tool['name']} (${tool['permission']}): ${tool['description']}',
      );
    }
    buffer.writeln('\nCall the matching tool directly by its name.');
    return ToolResult.ok(buffer.toString());
  }
}
