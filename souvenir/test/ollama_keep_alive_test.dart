import 'dart:convert';
import 'dart:io';

import 'package:souvenir/souvenir.dart';
import 'package:test/test.dart';

/// Request-shape tests for [OllamaEmbeddingProvider] against a stub HTTP
/// server — no real Ollama needed, so these run untagged.
void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> requests;

  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      requests.add(jsonDecode(body) as Map<String, dynamic>);
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'embeddings': [List.filled(4, 0.1)],
        }));
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  OllamaEmbeddingProvider provider({Object? keepAlive}) =>
      OllamaEmbeddingProvider(
        model: 'stub-model',
        dimensions: 4,
        baseUrl: 'http://127.0.0.1:${server.port}',
        keepAlive: keepAlive,
      );

  test('omits keep_alive by default', () async {
    await provider().embed('hello');
    expect(requests.single.containsKey('keep_alive'), isFalse);
  });

  test('sends int keep_alive as a JSON number', () async {
    await provider(keepAlive: -1).embed('hello');
    expect(requests.single['keep_alive'], -1);
  });

  test('sends duration-string keep_alive verbatim', () async {
    await provider(keepAlive: '24h').embed('hello');
    expect(requests.single['keep_alive'], '24h');
  });

  test('rejects keep_alive of unsupported type', () {
    expect(() => provider(keepAlive: 1.5), throwsA(isA<AssertionError>()));
  });
}
