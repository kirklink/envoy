import 'environmental_item.dart';

/// Abstract storage for environmental memory observations.
///
/// The default implementation is [InMemoryEnvironmentalMemoryStore].
/// A SQLite implementation can be added later if the experiment proves
/// valuable and persistence across restarts is needed.
abstract class EnvironmentalMemoryStore {
  /// Called once at startup.
  Future<void> initialize();

  /// Inserts a new environmental observation.
  Future<void> insert(EnvironmentalItem item);

  /// Updates an existing item's content, importance, or source episode IDs.
  Future<void> update(
    String id, {
    String? content,
    double? importance,
    List<String>? sourceEpisodeIds,
  });

  /// Returns all active observations.
  Future<List<EnvironmentalItem>> allActiveItems();

  /// Finds active observations in the given category whose content is
  /// similar to [content]. Used for merge detection during consolidation.
  /// No session filter — environmental observations are global.
  Future<List<EnvironmentalItem>> findSimilar(
    String content,
    EnvironmentalCategory category,
  );

  /// Marks a single item as decayed.
  Future<void> markDecayed(String id);

  /// Returns the count of active observations.
  Future<int> activeItemCount();

  /// Bumps access count and last accessed timestamp for the given IDs.
  Future<void> updateAccessStats(List<String> ids);

  /// Decays importance for observations not accessed within [inactivePeriod].
  /// Items that fall below [floorThreshold] are marked as decayed.
  /// Returns the number of items that crossed the floor threshold.
  Future<int> applyImportanceDecay({
    required Duration inactivePeriod,
    required double decayRate,
    required double floorThreshold,
  });

  /// Cleanup.
  Future<void> close();
}

/// In-memory implementation of [EnvironmentalMemoryStore].
///
/// Suitable for the experimental phase where persistence across agent
/// restarts is not required.
class InMemoryEnvironmentalMemoryStore implements EnvironmentalMemoryStore {
  final List<EnvironmentalItem> _items = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> insert(EnvironmentalItem item) async {
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
    _items[index] = EnvironmentalItem(
      id: item.id,
      content: content ?? item.content,
      category: item.category,
      importance: importance ?? item.importance,
      sourceEpisodeIds: sourceEpisodeIds ?? item.sourceEpisodeIds,
      createdAt: item.createdAt,
      updatedAt: DateTime.now().toUtc(),
      lastAccessed: item.lastAccessed,
      accessCount: item.accessCount,
      status: item.status,
    );
  }

  @override
  Future<List<EnvironmentalItem>> allActiveItems() async {
    return _items.where((i) => i.isActive).toList();
  }

  @override
  Future<List<EnvironmentalItem>> findSimilar(
    String content,
    EnvironmentalCategory category,
  ) async {
    final queryTokens = _tokenize(content);
    if (queryTokens.isEmpty) return [];

    final candidates =
        _items.where((i) => i.isActive && i.category == category).toList();

    final scored = <({EnvironmentalItem item, double overlap})>[];
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
  Future<void> markDecayed(String id) async {
    for (final item in _items) {
      if (item.id == id && item.status == EnvironmentalItemStatus.active) {
        item.status = EnvironmentalItemStatus.decayed;
        return;
      }
    }
  }

  @override
  Future<int> activeItemCount() async {
    return _items.where((i) => i.isActive).length;
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
  Future<int> applyImportanceDecay({
    required Duration inactivePeriod,
    required double decayRate,
    required double floorThreshold,
  }) async {
    final now = DateTime.now().toUtc();
    final cutoff = now.subtract(inactivePeriod);
    var floored = 0;

    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (!item.isActive) continue;

      // Decay items not accessed within the inactive period.
      final lastActivity = item.lastAccessed ?? item.updatedAt;
      if (lastActivity.isBefore(cutoff)) {
        final newImportance = item.importance * decayRate;

        if (newImportance < floorThreshold) {
          item.status = EnvironmentalItemStatus.decayed;
          floored++;
        } else {
          // Replace item with updated importance.
          _items[i] = EnvironmentalItem(
            id: item.id,
            content: item.content,
            category: item.category,
            importance: newImportance,
            sourceEpisodeIds: item.sourceEpisodeIds,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            lastAccessed: item.lastAccessed,
            accessCount: item.accessCount,
            status: item.status,
          );
        }
      }
    }

    return floored;
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
