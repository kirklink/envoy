import 'dart:convert';
import 'dart:io';

import 'embedding_provider.dart';

/// [EmbeddingProvider] backed by a local Ollama instance.
///
/// Calls the `/api/embed` endpoint to generate vectors. Requires Ollama
/// running with an embedding model pulled (e.g. `all-minilm`).
///
/// ```dart
/// final embeddings = OllamaEmbeddingProvider(
///   model: 'all-minilm',       // 384 dimensions
///   baseUrl: 'http://127.0.0.1:11434',
/// );
/// final vector = await embeddings.embed('User likes rabbits');
/// ```
class OllamaEmbeddingProvider implements EmbeddingProvider {
  final String _model;
  final Uri _endpoint;
  final HttpClient _client;

  @override
  final int dimensions;

  /// Creates a provider targeting [model] on [baseUrl].
  ///
  /// [dimensions] must match the model's output size (384 for all-minilm,
  /// 768 for nomic-embed-text, etc.).
  OllamaEmbeddingProvider({
    required String model,
    required this.dimensions,
    String baseUrl = 'http://127.0.0.1:11434',
    HttpClient? client,
  })  : _model = model,
        _endpoint = Uri.parse('$baseUrl/api/embed'),
        _client = client ?? HttpClient();

  @override
  Future<List<double>> embed(String text) async {
    final request = await _client.postUrl(_endpoint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'model': _model, 'input': text}));

    final response = await request.close();
    if (response.statusCode != 200) {
      final body = await response.transform(utf8.decoder).join();
      throw EmbeddingException(
        'Ollama returned ${response.statusCode}: $body',
      );
    }

    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final embeddings = json['embeddings'] as List;
    if (embeddings.isEmpty) {
      throw EmbeddingException('Ollama returned empty embeddings');
    }

    final vector = (embeddings[0] as List).cast<double>();
    if (vector.length != dimensions) {
      throw EmbeddingException(
        'Expected $dimensions dimensions, got ${vector.length}',
      );
    }
    return vector;
  }
}

/// Thrown when an embedding request fails.
class EmbeddingException implements Exception {
  final String message;
  EmbeddingException(this.message);

  @override
  String toString() => 'EmbeddingException: $message';
}
