import 'task_item.dart';

/// Abstract storage for task memory items.
///
/// The default implementation is [InMemoryTaskMemoryStore]. A SQLite
/// implementation can be added later for persistence across agent restarts.
abstract class TaskMemoryStore {
  /// Called once at startup.
  Future<void> initialize();

  /// Inserts a new task item.
  Future<void> insert(TaskItem item);

  /// Updates an existing item's content, importance, or source episode IDs.
  Future<void> update(
    String id, {
    String? content,
    double? importance,
    List<String>? sourceEpisodeIds,
  });

  /// Returns all active items for the given session.
  Future<List<TaskItem>> activeItemsForSession(String sessionId);

  /// Returns all active items across all sessions.
  Future<List<TaskItem>> allActiveItems();

  /// Finds active items in the given category and session whose content
  /// is similar to [content]. Used for merge detection during consolidation.
  /// Results are ordered by descending similarity.
  Future<List<TaskItem>> findSimilar(
    String content,
    TaskItemCategory category,
    String sessionId,
  );

  /// Expires all active items for the given session.
  /// Returns the number of items expired.
  Future<int> expireSession(String sessionId, DateTime expiredAt);

  /// Expires a single item by ID.
  Future<void> expireItem(String id, DateTime expiredAt);

  /// Returns the count of active items for the given session.
  Future<int> activeItemCount(String sessionId);

  /// Bumps access count and last accessed timestamp for the given IDs.
  Future<void> updateAccessStats(List<String> ids);

  /// Cleanup.
  Future<void> close();
}

/// In-memory implementation of [TaskMemoryStore].
///
/// Suitable for the default case where task memory does not need to
/// survive agent restarts. Fast, zero-dependency, no SQLite needed.
class InMemoryTaskMemoryStore implements TaskMemoryStore {
  final List<TaskItem> _items = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> insert(TaskItem item) async {
    _items.add(item);
  }

  @override
  Future<void> update(
    String id, {
    String? content,
    double? importance,
    List<String>? sourceEpisodeIds,
  }) async {
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;

    final item = _items[index];
    _items[index] = TaskItem(
      id: item.id,
      content: content ?? item.content,
      category: item.category,
      importance: importance ?? item.importance,
      sessionId: item.sessionId,
      sourceEpisodeIds: sourceEpisodeIds ?? item.sourceEpisodeIds,
      createdAt: item.createdAt,
      updatedAt: DateTime.now().toUtc(),
      lastAccessed: item.lastAccessed,
      accessCount: item.accessCount,
      status: item.status,
      invalidAt: item.invalidAt,
    );
  }

  @override
  Future<List<TaskItem>> activeItemsForSession(String sessionId) async {
    return _items
        .where((i) => i.sessionId == sessionId && i.isActive)
        .toList();
  }

  @override
  Future<List<TaskItem>> allActiveItems() async {
    return _items.where((i) => i.isActive).toList();
  }

  @override
  Future<List<TaskItem>> findSimilar(
    String content,
    TaskItemCategory category,
    String sessionId,
  ) async {
    final queryTokens = _tokenize(content);
    if (queryTokens.isEmpty) return [];

    final candidates = _items
        .where(
            (i) => i.isActive && i.category == category && i.sessionId == sessionId)
        .toList();

    final scored = <({TaskItem item, double overlap})>[];
    for (final candidate in candidates) {
      final candidateTokens = _tokenize(candidate.content);
      final intersection = queryTokens.intersection(candidateTokens);
      final union = queryTokens.union(candidateTokens);
      if (union.isEmpty) continue;
      final jaccard = intersection.length / union.length;
      if (jaccard > 0) {
        scored.add((item: candidate, overlap: jaccard));
      }
    }

    scored.sort((a, b) => b.overlap.compareTo(a.overlap));
    return scored.map((s) => s.item).toList();
  }

  @override
  Future<int> expireSession(String sessionId, DateTime expiredAt) async {
    var count = 0;
    for (final item in _items) {
      if (item.sessionId == sessionId && item.status == TaskItemStatus.active) {
        item.status = TaskItemStatus.expired;
        item.invalidAt = expiredAt;
        count++;
      }
    }
    return count;
  }

  @override
  Future<void> expireItem(String id, DateTime expiredAt) async {
    for (final item in _items) {
      if (item.id == id && item.status == TaskItemStatus.active) {
        item.status = TaskItemStatus.expired;
        item.invalidAt = expiredAt;
        return;
      }
    }
  }

  @override
  Future<int> activeItemCount(String sessionId) async {
    return _items
        .where((i) => i.sessionId == sessionId && i.isActive)
        .length;
  }

  @override
  Future<void> updateAccessStats(List<String> ids) async {
    final idSet = ids.toSet();
    final now = DateTime.now().toUtc();
    for (final item in _items) {
      if (idSet.contains(item.id)) {
        item.accessCount++;
        item.lastAccessed = now;
      }
    }
  }

  @override
  Future<void> close() async {}

  /// Total number of items (testing convenience).
  int get length => _items.length;

  /// Number of active items (testing convenience).
  int get activeCount => _items.where((i) => i.isActive).length;

  /// Tokenizes text into lowercase word tokens for Jaccard similarity.
  static Set<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 2)
        .toSet();
  }
}
