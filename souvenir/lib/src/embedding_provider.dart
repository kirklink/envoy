/// Abstract provider for text embeddings.
///
/// Implementations wrap a specific embedding service (Ollama, OpenAI, Voyage,
/// etc.). The memory system is agnostic — it calls [embed] and stores the
/// result.
///
/// ```dart
/// class OllamaEmbeddingProvider implements EmbeddingProvider {
///   @override
///   int get dimensions => 384;
///
///   @override
///   Future<List<double>> embed(String text) async {
///     // call Ollama API
///   }
/// }
/// ```
abstract class EmbeddingProvider {
  /// Embeds [text] into a fixed-length vector.
  Future<List<double>> embed(String text);

  /// The dimensionality of vectors returned by [embed].
  int get dimensions;
}
