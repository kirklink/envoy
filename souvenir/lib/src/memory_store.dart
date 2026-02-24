import 'stored_memory.dart';

/// A memory with its BM25 relevance score from full-text search.
class FtsMatch {
  /// The matched memory.
  final StoredMemory memory;

  /// BM25 relevance score (higher = more relevant).
  final double score;

  const FtsMatch({required this.memory, required this.score});
}

/// Unified storage for all memory components.
///
/// All memories from all components (task, durable, environmental) live in
/// one store. The [StoredMemory.component] field identifies origin; recall
/// queries the full index regardless of component.
///
/// Entity graph (entities + relationships) is also stored here and shared
/// across all components.
abstract class MemoryStore {
  /// Initialize storage (create tables, indexes).
  Future<void> initialize();

  /// Insert a memory.
  Future<void> insert(StoredMemory memory);

  /// Partially update a memory by ID. Only non-null fields are updated.
  /// Always bumps [StoredMemory.updatedAt].
  Future<void> update(
    String id, {
    String? content,
    double? importance,
    List<String>? entityIds,
    List<double>? embedding,
    String? status,
    String? supersededBy,
    DateTime? invalidAt,
    List<String>? sourceEpisodeIds,
  });

  /// Find active memories similar to [content] within [component].
  ///
  /// Used during consolidation for merge detection. Scoped to component
  /// because merge logic is component-specific. Optionally filtered by
  /// [category] and [sessionId].
  Future<List<StoredMemory>> findSimilar(
    String content,
    String component, {
    String? category,
    String? sessionId,
    int limit = 5,
  });

  /// Full-text search across ALL active memories.
  ///
  /// Returns memories ranked by BM25 relevance. No component filter — this
  /// is the unified recall path.
  Future<List<FtsMatch>> searchFts(String query, {int limit = 50});

  /// Load all active memories that have embeddings.
  ///
  /// Filtered to status = 'active' and temporally valid.
  Future<List<StoredMemory>> loadActiveWithEmbeddings();

  /// Load all active memories without embeddings.
  ///
  /// Used by the engine to generate embeddings post-consolidation.
  Future<List<StoredMemory>> findUnembeddedMemories({int limit = 100});

  // ── Entity graph ──────────────────────────────────────────────────────

  /// Upsert an entity (insert or update by name).
  Future<void> upsertEntity(Entity entity);

  /// Upsert a relationship (insert or update by composite key).
  Future<void> upsertRelationship(Relationship rel);

  /// Find entities whose name matches [query] (case-insensitive substring).
  Future<List<Entity>> findEntitiesByName(String query);

  /// Find all relationships involving [entityId].
  Future<List<Relationship>> findRelationshipsForEntity(String entityId);

  /// Find active memories associated with any of the given entity IDs.
  Future<List<StoredMemory>> findMemoriesByEntityIds(List<String> entityIds);

  // ── Lifecycle operations ──────────────────────────────────────────────

  /// Bump access_count and last_accessed for the given memory IDs.
  Future<void> updateAccessStats(List<String> ids);

  /// Decay importance for memories in [component] not accessed within
  /// [inactivePeriod]. Items falling below [floorThreshold] are marked
  /// as decayed. Returns the number of items that crossed the floor.
  Future<int> applyImportanceDecay({
    required String component,
    required Duration inactivePeriod,
    required double decayRate,
    double? floorThreshold,
  });

  /// Expire all active memories for [sessionId] in [component].
  Future<int> expireSession(String sessionId, String component);

  /// Expire a single memory by ID.
  Future<void> expireItem(String id);

  /// Mark a memory as superseded by another.
  Future<void> supersede(String oldId, String newId);

  /// Count active memories in [component], optionally filtered by [sessionId].
  Future<int> activeItemCount(String component, {String? sessionId});

  /// Return active memories for [sessionId] in [component].
  Future<List<StoredMemory>> activeItemsForSession(
    String sessionId,
    String component,
  );

  /// Cleanup.
  Future<void> close();
}
