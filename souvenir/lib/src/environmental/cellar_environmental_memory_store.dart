import 'package:cellar/cellar.dart';

import 'environmental_item.dart';
import 'environmental_memory_store.dart';

/// Cellar-backed [EnvironmentalMemoryStore] for persistent observations.
///
/// Uses FTS5 full-text search for similarity detection (replaces Jaccard).
/// Requires the collection to be registered before use.
class CellarEnvironmentalMemoryStore implements EnvironmentalMemoryStore {
  final Cellar _cellar;
  final String _collectionName;

  CellarEnvironmentalMemoryStore(this._cellar, this._collectionName);

  CollectionService get _svc => _cellar.collection(_collectionName);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> insert(EnvironmentalItem item) async {
    _svc.create({
      'content': item.content,
      'category': item.category.name,
      'importance': item.importance,
      'source_episode_ids': item.sourceEpisodeIds,
      'access_count': item.accessCount,
      'status': item.status.name,
    }, id: item.id);
  }

  @override
  Future<void> update(
    String id, {
    String? content,
    double? importance,
    List<String>? sourceEpisodeIds,
  }) async {
    final data = <String, dynamic>{};
    if (content != null) data['content'] = content;
    if (importance != null) data['importance'] = importance;
    if (sourceEpisodeIds != null) {
      data['source_episode_ids'] = sourceEpisodeIds;
    }
    if (data.isNotEmpty) _svc.update(id, data);
  }

  @override
  Future<List<EnvironmentalItem>> allActiveItems() async {
    final list = _svc.list(filter: 'status = "active"', limit: 10000);
    return list.items.map(_recordToItem).toList();
  }

  @override
  Future<List<EnvironmentalItem>> findSimilar(
    String content,
    EnvironmentalCategory category,
  ) async {
    final results = _svc.search(
      content,
      filter: 'category = "${category.name}" && status = "active"',
      limit: 10,
    );
    return results.items.map((sr) => _recordToItem(sr.record)).toList();
  }

  @override
  Future<void> markDecayed(String id) async {
    _svc.update(id, {'status': 'decayed'});
  }

  @override
  Future<int> activeItemCount() async {
    return _svc.list(filter: 'status = "active"', limit: 0).total;
  }

  @override
  Future<void> updateAccessStats(List<String> ids) async {
    if (ids.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      _cellar.rawQuery(
        'UPDATE $_collectionName SET access_count = access_count + 1, '
        'last_accessed = ?, updated_at = ? WHERE id = ?',
        [now, now, id],
      );
    }
  }

  @override
  Future<int> applyImportanceDecay({
    required Duration inactivePeriod,
    required double decayRate,
    required double floorThreshold,
  }) async {
    final cutoff =
        DateTime.now().subtract(inactivePeriod).toUtc().toIso8601String();
    final now = DateTime.now().toUtc().toIso8601String();

    // Step 1: Mark items below floor threshold as decayed.
    final flooredResult = _cellar.rawQuery(
      "UPDATE $_collectionName SET status = 'decayed', updated_at = ? "
      "WHERE status = 'active' "
      'AND importance * ? < ? '
      'AND ((last_accessed IS NOT NULL AND last_accessed < ?) '
      'OR (last_accessed IS NULL AND updated_at < ?))',
      [now, decayRate, floorThreshold, cutoff, cutoff],
    );

    // Step 2: Apply decay to remaining active items.
    _cellar.rawQuery(
      'UPDATE $_collectionName SET importance = importance * ?, updated_at = ? '
      "WHERE status = 'active' "
      'AND ((last_accessed IS NOT NULL AND last_accessed < ?) '
      'OR (last_accessed IS NULL AND updated_at < ?))',
      [decayRate, now, cutoff, cutoff],
    );

    return flooredResult.changes;
  }

  @override
  Future<void> close() async {}

  /// Total number of items (testing convenience).
  int get length => _svc.list(limit: 0).total;

  /// Number of active items (testing convenience).
  int get activeCount =>
      _svc.list(filter: 'status = "active"', limit: 0).total;

  static EnvironmentalItem _recordToItem(Record record) {
    final sourceIds = record['source_episode_ids'];
    return EnvironmentalItem(
      id: record.id,
      content: record['content'] as String,
      category: EnvironmentalCategory.values.firstWhere(
        (c) => c.name == (record['category'] as String),
      ),
      importance: (record['importance'] as num).toDouble(),
      sourceEpisodeIds: sourceIds is List
          ? sourceIds.cast<String>()
          : <String>[],
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      lastAccessed: record['last_accessed'] as DateTime?,
      accessCount: (record['access_count'] as num).toInt(),
      status: EnvironmentalItemStatus.values.firstWhere(
        (s) => s.name == (record['status'] as String),
        orElse: () => EnvironmentalItemStatus.active,
      ),
    );
  }
}
