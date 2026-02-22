import 'models/episode.dart';

/// Abstract storage for episodes.
///
/// Decouples the engine from any specific storage backend. Phase 1 uses
/// [InMemoryEpisodeStore]; later phases add SQLite via Stanza.
abstract class EpisodeStore {
  /// Persists a batch of episodes.
  Future<void> insert(List<Episode> episodes);

  /// Returns all episodes not yet marked as consolidated.
  Future<List<Episode>> fetchUnconsolidated();

  /// Marks the given episodes as consolidated.
  Future<void> markConsolidated(List<Episode> episodes);
}

/// In-memory episode store for testing and Phase 1.
class InMemoryEpisodeStore implements EpisodeStore {
  final List<Episode> _episodes = [];
  final Set<String> _consolidatedIds = {};

  @override
  Future<void> insert(List<Episode> episodes) async {
    _episodes.addAll(episodes);
  }

  @override
  Future<List<Episode>> fetchUnconsolidated() async {
    return _episodes
        .where((e) => !_consolidatedIds.contains(e.id))
        .toList();
  }

  @override
  Future<void> markConsolidated(List<Episode> episodes) async {
    for (final e in episodes) {
      _consolidatedIds.add(e.id);
    }
  }

  /// Number of episodes in the store (testing convenience).
  int get length => _episodes.length;

  /// Number of unconsolidated episodes (testing convenience).
  int get unconsolidatedCount =>
      _episodes.where((e) => !_consolidatedIds.contains(e.id)).length;
}
