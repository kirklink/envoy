import 'package:cellar/cellar.dart';

import 'episode_store.dart';
import 'models/episode.dart';

/// Cellar-backed [EpisodeStore] for production use.
///
/// Stores episodes in a Cellar collection. Requires the collection to be
/// registered before use (handled by [SouvenirCellar]).
class CellarEpisodeStore implements EpisodeStore {
  final Cellar _cellar;
  final String _collectionName;

  CellarEpisodeStore(this._cellar, this._collectionName);

  CollectionService get _svc => _cellar.collection(_collectionName);

  @override
  Future<void> insert(List<Episode> episodes) async {
    if (episodes.isEmpty) return;
    _svc.batch(episodes
        .map((ep) => BatchCreate(
              {
                'session_id': ep.sessionId,
                'timestamp': ep.timestamp.toUtc(),
                'type': ep.type.name,
                'content': ep.content,
                'importance': ep.importance,
                'access_count': ep.accessCount,
                'consolidated': ep.consolidated,
              },
              id: ep.id,
            ))
        .toList());
  }

  @override
  Future<List<Episode>> fetchUnconsolidated() async {
    final list = _svc.list(
      filter: 'consolidated = false',
      sort: 'timestamp',
      limit: 10000,
    );
    return list.items.map(_recordToEpisode).toList();
  }

  @override
  Future<void> markConsolidated(List<Episode> episodes) async {
    if (episodes.isEmpty) return;
    _svc.batch(episodes
        .map((ep) => BatchUpdate(ep.id, {'consolidated': true}))
        .toList());
  }

  @override
  Future<int> deleteConsolidatedBefore(DateTime olderThan) async {
    final iso = olderThan.toUtc().toIso8601String();
    return _svc.deleteWhere('consolidated = true AND timestamp < "$iso"');
  }

  /// Total number of episodes (testing convenience).
  int get count => _svc.list(limit: 0).total;

  /// Number of unconsolidated episodes (testing convenience).
  int get unconsolidatedCount =>
      _svc.list(filter: 'consolidated = false', limit: 0).total;

  static Episode _recordToEpisode(Record record) {
    return Episode(
      id: record.id,
      sessionId: record['session_id'] as String,
      timestamp: record['timestamp'] as DateTime,
      type: EpisodeType.values.firstWhere(
        (t) => t.name == (record['type'] as String),
      ),
      content: record['content'] as String,
      importance: (record['importance'] as num).toDouble(),
      accessCount: (record['access_count'] as num).toInt(),
      consolidated: record['consolidated'] as bool,
    );
  }
}
