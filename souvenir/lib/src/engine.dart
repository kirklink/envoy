import 'embedding_provider.dart';
import 'episode_store.dart';
import 'llm_callback.dart';
import 'memory_component.dart';
import 'memory_store.dart';
import 'models/episode.dart';
import 'recall.dart';
import 'tokenizer.dart';

/// Souvenir v3: unified recall memory engine.
///
/// A registry and coordinator. Owns the shared [MemoryStore], episode buffer,
/// component list, and [UnifiedRecall] pipeline. Components handle
/// consolidation (extraction + storage); recall is unified across all
/// memories in the shared store.
///
/// ```dart
/// final store = InMemoryMemoryStore();
/// final souvenir = Souvenir(
///   components: [taskMemory, durableMemory, envMemory],
///   store: store,
///   recallConfig: RecallConfig(
///     componentWeights: {'durable': 1.5, 'task': 1.2},
///   ),
/// );
/// await souvenir.initialize();
/// ```
class Souvenir {
  /// Registered memory components.
  final List<MemoryComponent> components;

  /// Shared memory store used by all components and recall.
  final MemoryStore store;

  /// Unified recall pipeline.
  final UnifiedRecall _recall;

  /// Optional embedding provider for post-consolidation embedding generation.
  final EmbeddingProvider? _embeddings;

  final EpisodeStore _episodeStore;
  final int _flushThreshold;
  final int _defaultBudgetTokens;
  final List<Episode> _buffer = [];
  bool _initialized = false;

  /// Creates a Souvenir v3 engine.
  ///
  /// [store] is the shared memory store all components write to.
  /// [episodeStore] defaults to [InMemoryEpisodeStore].
  /// [recallConfig] controls signal weights, thresholds, and decay.
  /// [embeddings] is optional — when provided, the engine generates
  /// embeddings for new memories after each consolidation.
  /// [tokenizer] defaults to [ApproximateTokenizer].
  Souvenir({
    required this.components,
    required this.store,
    EpisodeStore? episodeStore,
    RecallConfig recallConfig = const RecallConfig(),
    EmbeddingProvider? embeddings,
    Tokenizer tokenizer = const ApproximateTokenizer(),
    int flushThreshold = 50,
    int defaultBudgetTokens = 4000,
  })  : _episodeStore = episodeStore ?? InMemoryEpisodeStore(),
        _embeddings = embeddings,
        _flushThreshold = flushThreshold,
        _defaultBudgetTokens = defaultBudgetTokens,
        _recall = UnifiedRecall(
          store: store,
          tokenizer: tokenizer,
          config: recallConfig,
          embeddings: embeddings,
        );

  /// The recall configuration (for observability).
  RecallConfig get recallConfig => _recall.config;

  /// Initializes the shared store and all components concurrently.
  /// Must be called before [record], [consolidate], or [recall].
  Future<void> initialize() async {
    await store.initialize();
    await Future.wait(components.map((c) => c.initialize()));
    _initialized = true;
  }

  /// Records an episode to the buffer. Auto-flushes at the threshold.
  Future<void> record(Episode episode) async {
    _requireInitialized();
    _buffer.add(episode);
    if (_buffer.length >= _flushThreshold) {
      await flush();
    }
  }

  /// Flushes all buffered episodes to the episode store. No-op if empty.
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    final batch = List<Episode>.of(_buffer);
    _buffer.clear();
    await _episodeStore.insert(batch);
  }

  /// Consolidates unconsolidated episodes across all components.
  ///
  /// 1. Flushes the buffer.
  /// 2. Fetches unconsolidated episodes from the episode store.
  /// 3. Passes them to all components concurrently (components write to
  ///    the shared [store]).
  /// 4. Marks episodes consolidated.
  /// 5. Generates embeddings for any unembedded memories.
  ///
  /// Returns empty list if no unconsolidated episodes exist.
  Future<List<ConsolidationReport>> consolidate(LlmCallback llm) async {
    _requireInitialized();
    await flush();

    final episodes = await _episodeStore.fetchUnconsolidated();
    if (episodes.isEmpty) return [];

    final reports = await Future.wait(
      components.map((c) => c.consolidate(episodes, llm)),
    );

    await _episodeStore.markConsolidated(episodes);

    // Post-consolidation: generate embeddings for new memories.
    if (_embeddings != null) {
      await _generateEmbeddings();
    }

    return reports;
  }

  /// Recalls relevant memories for a query.
  ///
  /// Delegates to the [UnifiedRecall] pipeline which queries the shared
  /// store with FTS5, vector similarity, and entity graph signals.
  Future<RecallResult> recall(String query, {int? budgetTokens}) async {
    _requireInitialized();
    return _recall.recall(
      query,
      budgetTokens: budgetTokens ?? _defaultBudgetTokens,
    );
  }

  /// Number of episodes currently buffered in working memory.
  int get bufferSize => _buffer.length;

  /// Flushes the buffer and closes all components and the store.
  Future<void> close() async {
    await flush();
    await Future.wait(components.map((c) => c.close()));
    await store.close();
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  /// Generates embeddings for memories that don't have them yet.
  Future<void> _generateEmbeddings() async {
    final unembedded = await store.findUnembeddedMemories();
    for (final mem in unembedded) {
      try {
        final vector = await _embeddings!.embed(mem.content);
        await store.update(mem.id, embedding: vector);
      } catch (_) {
        // Embedding failure is non-fatal — the memory is still searchable
        // via FTS and entity graph signals.
      }
    }
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Souvenir not initialized. Call initialize() first.');
    }
  }
}
