@Tags(['ollama'])
library;

import 'package:souvenir/souvenir.dart';
import 'package:test/test.dart';

/// Tests for [OllamaEmbeddingProvider].
///
/// Requires a running Ollama instance with `all-minilm` pulled:
///   ollama serve &
///   ollama pull all-minilm
///
/// Run with: dart test --tags ollama
/// Skip in CI by omitting the tag.
void main() {
  late OllamaEmbeddingProvider provider;

  setUpAll(() {
    provider = OllamaEmbeddingProvider(
      model: 'all-minilm',
      dimensions: 384,
    );
  });

  test('returns vector with correct dimensions', () async {
    final vector = await provider.embed('hello world');
    expect(vector, hasLength(384));
  });

  test('returns different vectors for different text', () async {
    final a = await provider.embed('I like cats');
    final b = await provider.embed('quantum mechanics');
    expect(a, isNot(equals(b)));
  });

  test('similar text produces high cosine similarity', () async {
    final a = await provider.embed('I enjoy programming in Dart');
    final b = await provider.embed('Dart programming is fun');
    expect(_cosine(a, b), greaterThan(0.7));
  });

  test('semantic bridging: animal query finds rabbits', () async {
    final query = await provider.embed('favourite animal');
    final rabbit = await provider.embed('User finds rabbits cute');
    final dart = await provider.embed('User prefers list-based Dart functions');

    final rabbitSim = _cosine(query, rabbit);
    final dartSim = _cosine(query, dart);

    expect(rabbitSim, greaterThan(dartSim),
        reason: '"favourite animal" should be closer to rabbits than Dart');
    expect(rabbitSim, greaterThan(0.3),
        reason: 'semantic bridge should produce meaningful similarity');
  });

  test('throws EmbeddingException for invalid model', () async {
    final bad = OllamaEmbeddingProvider(
      model: 'nonexistent-model-xyz',
      dimensions: 384,
    );
    expect(() => bad.embed('test'), throwsA(isA<EmbeddingException>()));
  });

  test('throws EmbeddingException for wrong dimensions', () async {
    final wrong = OllamaEmbeddingProvider(
      model: 'all-minilm',
      dimensions: 512, // all-minilm is 384
    );
    expect(() => wrong.embed('test'), throwsA(isA<EmbeddingException>()));
  });
}

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  final denom = (na * nb);
  if (denom == 0) return 0;
  return dot / _sqrt(denom);
}

double _sqrt(double x) {
  // Newton's method — avoids dart:math import for a test helper.
  var guess = x / 2;
  for (var i = 0; i < 20; i++) {
    guess = (guess + x / guess) / 2;
  }
  return guess;
}
