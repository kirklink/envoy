/// Storage statistics for observability.
///
/// Returned by [Souvenir.stats()] and [MemoryStore.stats()].
class StoreStats {
  /// Total number of memories (all statuses).
  final int totalMemories;

  /// Number of active memories.
  final int activeMemories;

  /// Number of expired memories (tombstoned).
  final int expiredMemories;

  /// Number of superseded memories (tombstoned).
  final int supersededMemories;

  /// Number of decayed memories (tombstoned).
  final int decayedMemories;

  /// Number of active memories with embeddings.
  final int embeddedMemories;

  /// Number of entities in the graph.
  final int entities;

  /// Number of relationships in the graph.
  final int relationships;

  /// Breakdown of active memories by component name.
  final Map<String, int> activeByComponent;

  const StoreStats({
    required this.totalMemories,
    required this.activeMemories,
    required this.expiredMemories,
    required this.supersededMemories,
    required this.decayedMemories,
    required this.embeddedMemories,
    required this.entities,
    required this.relationships,
    required this.activeByComponent,
  });
}
