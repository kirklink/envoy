import 'package:envoy/envoy.dart';
import 'package:http/http.dart' as http;

import 'schema_validating_tool.dart';

/// Fetches the content of a URL via HTTP GET.
///
/// Note: allowlist enforcement is deferred to Phase 3. Any reachable URL
/// can be fetched if the agent has network permission.
class FetchUrlTool extends Tool with SchemaValidatingTool {
  final http.Client _client;

  FetchUrlTool({http.Client? client}) : _client = client ?? http.Client();

  @override
  String get name => 'fetch_url';

  @override
  String get description =>
      'Fetch the content of a URL via HTTP GET. Returns the response body as text.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'The URL to fetch',
          },
          'headers': {
            'type': 'object',
            'description': 'Optional HTTP headers as key-value pairs',
          },
        },
        'required': ['url'],
      };

  @override
  ToolPermission get permission => ToolPermission.network;

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final url = input['url'] as String?;
    if (url == null || url.isEmpty) {
      return const ToolResult.err('url is required');
    }

    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return ToolResult.err('invalid URL: $url');
    }

    final rawHeaders = input['headers'] as Map<String, dynamic>?;
    final headers = rawHeaders?.map(
      (k, v) => MapEntry(k, v.toString()),
    );

    try {
      final response = await _client.get(uri, headers: headers);
      if (response.statusCode >= 400) {
        return ToolResult.err(
          'HTTP ${response.statusCode}: ${response.reasonPhrase}',
        );
      }
      return ToolResult.ok(response.body);
    } catch (e) {
      return ToolResult.err('request failed: $e');
    }
  }
}
