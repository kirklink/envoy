import 'package:envoy/envoy.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:http/http.dart' as http;

import 'schema_validating_tool.dart';

/// Fetches the content of a URL via HTTP GET.
///
/// HTML responses are automatically converted to markdown using html2md,
/// with `<script>` and `<style>` elements stripped. Non-HTML responses
/// (JSON, XML, plain text) are returned unchanged.
///
/// Responses exceeding [maxResponseLength] characters are truncated with
/// a notice appended so the agent knows the output is partial.
///
/// Note: allowlist enforcement is deferred to Phase 3. Any reachable URL
/// can be fetched if the agent has network permission.
class FetchUrlTool extends Tool with SchemaValidatingTool {
  final http.Client _client;

  /// Maximum characters in the returned output. Responses exceeding this
  /// limit are truncated and a notice is appended.
  final int maxResponseLength;

  /// Default response length cap: ~8K tokens at 4 chars/token.
  static const defaultMaxResponseLength = 32000;

  FetchUrlTool({
    http.Client? client,
    this.maxResponseLength = defaultMaxResponseLength,
  }) : _client = client ?? http.Client();

  @override
  String get name => 'fetch_url';

  @override
  String get description =>
      'Fetch the content of a URL via HTTP GET. '
      'HTML responses are automatically converted to clean markdown. '
      'Returns the response body as text.';

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

      var body = response.body;

      // Convert HTML responses to markdown.
      if (_isHtml(response.headers['content-type'])) {
        body = html2md.convert(body, ignore: ['script', 'style']);
      }

      // Cap response size.
      body = _truncate(body);

      return ToolResult.ok(body);
    } catch (e) {
      return ToolResult.err('request failed: $e');
    }
  }

  /// Returns `true` if [contentType] indicates an HTML response.
  static bool _isHtml(String? contentType) {
    if (contentType == null) return false;
    final mimeType = contentType.toLowerCase().split(';').first.trim();
    return mimeType == 'text/html' || mimeType == 'application/xhtml+xml';
  }

  /// Truncates [text] to [maxResponseLength], appending a notice if trimmed.
  String _truncate(String text) {
    if (text.length <= maxResponseLength) return text;
    final truncated = text.substring(0, maxResponseLength);
    return '$truncated\n\n[Truncated: response exceeded $maxResponseLength characters]';
  }
}
