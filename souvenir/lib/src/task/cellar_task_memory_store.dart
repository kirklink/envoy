import 'package:cellar/cellar.dart';

import 'task_item.dart';
import 'task_memory_store.dart';

/// Cellar-backed [TaskMemoryStore] for persistent task memory.
///
/// Uses FTS5 full-text search for similarity detection (replaces Jaccard).
/// Requires the collection to be registered before use.
class CellarTaskMemoryStore implements TaskMemoryStore {
  final Cellar _cellar;
  final String _collectionName;

  CellarTaskMemoryStore(this._cellar, this._collectionName);

  CollectionService get _svc => _cellar.collection(_collectionName);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> insert(TaskItem item) async {
    _svc.create({
      'content': item.content,
      'category': item.category.name,
      'importance': item.importance,
      'session_id': item.sessionId,
      'source_episode_ids': item.sourceEpisodeIds,
      'access_count': item.accessCount,
      'status': item.status.name,
      'invalid_at': item.invalidAt,
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
  Future<List<TaskItem>> activeItemsForSession(String sessionId) async {
    final list = _svc.list(
      filter: 'session_id = "$sessionId" && status = "active"',
      limit: 10000,
    );
    return list.items.map(_recordToTaskItem).toList();
  }

  @override
  Future<List<TaskItem>> allActiveItems() async {
    final list = _svc.list(filter: 'status = "active"', limit: 10000);
    return list.items.map(_recordToTaskItem).toList();
  }

  @override
  Future<List<TaskItem>> findSimilar(
    String content,
    TaskItemCategory category,
    String sessionId,
  ) async {
    final results = _svc.search(
      content,
      filter:
          'category = "${category.name}" && session_id = "$sessionId" && status = "active"',
      limit: 10,
    );
    return results.items.map((sr) => _recordToTaskItem(sr.record)).toList();
  }

  @override
  Future<int> expireSession(String sessionId, DateTime expiredAt) async {
    return _svc.updateWhere(
      'session_id = "$sessionId" && status = "active"',
      {'status': 'expired', 'invalid_at': expiredAt},
    );
  }

  @override
  Future<void> expireItem(String id, DateTime expiredAt) async {
    _svc.update(id, {'status': 'expired', 'invalid_at': expiredAt});
  }

  @override
  Future<int> activeItemCount(String sessionId) async {
    return _svc
        .list(
          filter: 'session_id = "$sessionId" && status = "active"',
          limit: 0,
        )
        .total;
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
  Future<void> close() async {}

  /// Total number of items (testing convenience).
  int get length => _svc.list(limit: 0).total;

  /// Number of active items (testing convenience).
  int get activeCount =>
      _svc.list(filter: 'status = "active"', limit: 0).total;

  static TaskItem _recordToTaskItem(Record record) {
    final sourceIds = record['source_episode_ids'];
    return TaskItem(
      id: record.id,
      content: record['content'] as String,
      category: TaskItemCategory.values.firstWhere(
        (c) => c.name == (record['category'] as String),
      ),
      importance: (record['importance'] as num).toDouble(),
      sessionId: record['session_id'] as String,
      sourceEpisodeIds: sourceIds is List
          ? sourceIds.cast<String>()
          : <String>[],
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      lastAccessed: record['last_accessed'] as DateTime?,
      accessCount: (record['access_count'] as num).toInt(),
      status: TaskItemStatus.values.firstWhere(
        (s) => s.name == (record['status'] as String),
        orElse: () => TaskItemStatus.active,
      ),
      invalidAt: record['invalid_at'] as DateTime?,
    );
  }
}
