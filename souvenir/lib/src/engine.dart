import 'budget.dart';
import 'episode_store.dart';
import 'llm_callback.dart';
import 'memory_component.dart';
import 'mixer.dart';
import 'models/episode.dart';

/// Souvenir v2: composable memory engine.
///
/// A registry and coordinator. Owns the episode buffer, component list,
/// budget, and mixer. Does not contain memory logic itself — that lives
/// in [MemoryComponent] implementations.
///
/// ```dart
/// final souvenir = Souvenir(
///   components: [taskMemory, durableMemory],
///   budget: Budget(
///     totalTokens: 4000,
///     allocation: {'task': 1000, 'durable': 3000},
///     tokenizer: ApproximateTokenizer(),
///   ),
///   mixer: WeightedMixer(weights: {'task': 1.2, 'durable': 1.5}),
/// );
/// await souvenir.initialize();
/// ```
class Souvenir {
  /// Registered memory components.
  final List<MemoryComponent> components;

  /// Token budget with per-component allocation.
  final Budget budget;

  /// Mixer for combining recall results across components.
  final Mixer mixer;

  final EpisodeStore _store;
  final int _flushThreshold;
  final List<Episode> _buffer = [];
  bool _initialized = false;

  /// Creates a Souvenir v2 engine.
  ///
  /// [store] defaults to [InMemoryEpisodeStore]. [flushThreshold] defaults
  /// to 50 (matching v1).
  Souvenir({
    required this.components,
    required this.budget,
    required this.mixer,
    EpisodeStore? store,
    int flushThreshold = 50,
  })  : _store = store ?? InMemoryEpisodeStore(),
        _flushThreshold = flushThreshold;

  /// Initializes all components concurrently. Must be called before
  /// [record], [consolidate], or [recall].
  Future<void> initialize() async {
    await Future.wait(components.map((c) => c.initialize()));
    _initialized = true;
  }

  /// Records an episode to the buffer. Auto-flushes at [flushThreshold].
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
    await _store.insert(batch);
  }

  /// Consolidates unconsolidated episodes across all components.
  ///
  /// Flushes the buffer first, then fetches unconsolidated episodes,
  /// passes them to all components concurrently, and marks them
  /// consolidated. Returns empty list if no unconsolidated episodes.
  Future<List<ConsolidationReport>> consolidate(LlmCallback llm) async {
    _requireInitialized();
    await flush();

    final episodes = await _store.fetchUnconsolidated();
    if (episodes.isEmpty) return [];

    final reports = await Future.wait(
      components.map((c) => c.consolidate(
            episodes,
            llm,
            budget.forComponent(c.name),
          )),
    );

    await _store.markConsolidated(episodes);
    return reports;
  }

  /// Recalls relevant items from all components and mixes them.
  ///
  /// Queries all components concurrently, then passes results to
  /// the [mixer] for ranking and budget trimming.
  Future<MixResult> recall(String query) async {
    _requireInitialized();

    final results = await Future.wait(
      components.map((c) async => MapEntry(
            c.name,
            await c.recall(query, budget.forComponent(c.name)),
          )),
    );

    final componentRecalls = Map.fromEntries(results);
    return mixer.mix(componentRecalls, budget);
  }

  /// Number of episodes currently buffered in working memory.
  int get bufferSize => _buffer.length;

  /// Flushes the buffer and closes all components.
  Future<void> close() async {
    await flush();
    await Future.wait(components.map((c) => c.close()));
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Souvenir not initialized. Call initialize() first.');
    }
  }
}
