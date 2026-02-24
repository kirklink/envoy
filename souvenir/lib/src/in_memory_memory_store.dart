import 'memory_store.dart';
import 'stored_memory.dart';

/// In-memory implementation of [MemoryStore].
///
/// Suitable for unit tests and lightweight usage. FTS is approximated with
/// Jaccard token overlap. No SQLite dependency.
class InMemoryMemoryStore implements MemoryStore {
  final List<StoredMemory> _memories = [];
  final List<Entity> _entities = [];
  final List<Relationship> _relationships = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> insert(StoredMemory memory) async {
    _memories.add(memory);
  }

  @override
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
  }) async {
    final index = _memories.indexWhere((m) => m.id == id);
    if (index == -1) return;

    final m = _memories[index];
    _memories[index] = StoredMemory(
      id: m.id,
      content: content ?? m.content,
      component: m.component,
      category: m.category,
      importance: importance ?? m.importance,
      sessionId: m.sessionId,
      sourceEpisodeIds: sourceEpisodeIds ?? m.sourceEpisodeIds,
      embedding: embedding ?? m.embedding,
      entityIds: entityIds ?? m.entityIds,
      createdAt: m.createdAt,
      updatedAt: DateTime.now().toUtc(),
      lastAccessed: m.lastAccessed,
      accessCount: m.accessCount,
      status: status != null ? _parseStatus(status) : m.status,
      validAt: m.validAt,
      invalidAt: invalidAt ?? m.invalidAt,
      supersededBy: supersededBy ?? m.supersededBy,
    );
  }

  @override
  Future<List<StoredMemory>> findSimilar(
    String content,
    String component, {
    String? category,
    String? sessionId,
    int limit = 5,
  }) async {
    final queryTokens = _tokenize(content);
    if (queryTokens.isEmpty) return [];

    final candidates = _memories.where((m) {
      if (!m.isActive) return false;
      if (m.component != component) return false;
      if (category != null && m.category != category) return false;
      if (sessionId != null && m.sessionId != sessionId) return false;
      return true;
    }).toList();

    final scored = <({StoredMemory memory, double overlap})>[];
    for (final candidate in candidates) {
      final candidateTokens = _tokenize(candidate.content);
      final intersection = queryTokens.intersection(candidateTokens);
      final union = queryTokens.union(candidateTokens);
      if (union.isEmpty) continue;
      final jaccard = intersection.length / union.length;
      if (jaccard > 0) {
        scored.add((memory: candidate, overlap: jaccard));
      }
    }

    scored.sort((a, b) => b.overlap.compareTo(a.overlap));
    return scored.take(limit).map((s) => s.memory).toList();
  }

  @override
  Future<List<FtsMatch>> searchFts(String query, {int limit = 50}) async {
    // Approximate FTS with Jaccard token overlap.
    final queryTokens = _tokenize(query);
    if (queryTokens.isEmpty) return [];

    final scored = <FtsMatch>[];
    for (final m in _memories) {
      if (!m.isActive) continue;
      final candidateTokens = _tokenize(m.content);
      final intersection = queryTokens.intersection(candidateTokens);
      final union = queryTokens.union(candidateTokens);
      if (union.isEmpty) continue;
      final jaccard = intersection.length / union.length;
      if (jaccard > 0) {
        scored.add(FtsMatch(memory: m, score: jaccard));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList();
  }

  @override
  Future<List<StoredMemory>> loadActiveWithEmbeddings() async {
    return _memories
        .where((m) => m.isActive && m.embedding != null)
        .toList();
  }

  @override
  Future<List<StoredMemory>> findUnembeddedMemories({int limit = 100}) async {
    return _memories
        .where((m) => m.isActive && m.embedding == null)
        .take(limit)
        .toList();
  }

  // ── Entity graph ──────────────────────────────────────────────────────

  @override
  Future<void> upsertEntity(Entity entity) async {
    final index = _entities.indexWhere(
      (e) => e.name.toLowerCase() == entity.name.toLowerCase(),
    );
    if (index >= 0) {
      _entities[index] = entity;
    } else {
      _entities.add(entity);
    }
  }

  @override
  Future<void> upsertRelationship(Relationship rel) async {
    final index = _relationships.indexWhere(
      (r) =>
          r.fromEntity == rel.fromEntity &&
          r.toEntity == rel.toEntity &&
          r.relation == rel.relation,
    );
    if (index >= 0) {
      _relationships[index] = rel;
    } else {
      _relationships.add(rel);
    }
  }

  @override
  Future<List<Entity>> findEntitiesByName(String query) async {
    final lower = query.toLowerCase();
    final words = lower
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2)
        .toList();
    if (words.isEmpty) return [];

    return _entities.where((e) {
      final name = e.name.toLowerCase();
      return words.any((w) => name.contains(w));
    }).toList();
  }

  @override
  Future<List<Relationship>> findRelationshipsForEntity(
    String entityId,
  ) async {
    return _relationships
        .where((r) => r.fromEntity == entityId || r.toEntity == entityId)
        .toList();
  }

  @override
  Future<List<StoredMemory>> findMemoriesByEntityIds(
    List<String> entityIds,
  ) async {
    final idSet = entityIds.toSet();
    return _memories
        .where(
          (m) => m.isActive && m.entityIds.any((eid) => idSet.contains(eid)),
        )
        .toList();
  }

  // ── Lifecycle operations ──────────────────────────────────────────────

  @override
  Future<void> updateAccessStats(List<String> ids) async {
    final idSet = ids.toSet();
    final now = DateTime.now().toUtc();
    for (var i = 0; i < _memories.length; i++) {
      final m = _memories[i];
      if (idSet.contains(m.id)) {
        _memories[i] = StoredMemory(
          id: m.id,
          content: m.content,
          component: m.component,
          category: m.category,
          importance: m.importance,
          sessionId: m.sessionId,
          sourceEpisodeIds: m.sourceEpisodeIds,
          embedding: m.embedding,
          entityIds: m.entityIds,
          createdAt: m.createdAt,
          updatedAt: m.updatedAt,
          lastAccessed: now,
          accessCount: m.accessCount + 1,
          status: m.status,
          validAt: m.validAt,
          invalidAt: m.invalidAt,
          supersededBy: m.supersededBy,
        );
      }
    }
  }

  @override
  Future<int> applyImportanceDecay({
    required String component,
    required Duration inactivePeriod,
    required double decayRate,
    double? floorThreshold,
  }) async {
    final now = DateTime.now().toUtc();
    final cutoff = now.subtract(inactivePeriod);
    var floored = 0;

    for (var i = 0; i < _memories.length; i++) {
      final m = _memories[i];
      if (!m.isActive || m.component != component) continue;

      final lastActivity = m.lastAccessed ?? m.updatedAt;
      if (lastActivity.isBefore(cutoff)) {
        final newImportance = m.importance * decayRate;

        if (floorThreshold != null && newImportance < floorThreshold) {
          _memories[i] = StoredMemory(
            id: m.id,
            content: m.content,
            component: m.component,
            category: m.category,
            importance: newImportance,
            sessionId: m.sessionId,
            sourceEpisodeIds: m.sourceEpisodeIds,
            embedding: m.embedding,
            entityIds: m.entityIds,
            createdAt: m.createdAt,
            updatedAt: m.updatedAt,
            lastAccessed: m.lastAccessed,
            accessCount: m.accessCount,
            status: MemoryStatus.decayed,
            validAt: m.validAt,
            invalidAt: m.invalidAt,
            supersededBy: m.supersededBy,
          );
          floored++;
        } else {
          _memories[i] = StoredMemory(
            id: m.id,
            content: m.content,
            component: m.component,
            category: m.category,
            importance: newImportance,
            sessionId: m.sessionId,
            sourceEpisodeIds: m.sourceEpisodeIds,
            embedding: m.embedding,
            entityIds: m.entityIds,
            createdAt: m.createdAt,
            updatedAt: m.updatedAt,
            lastAccessed: m.lastAccessed,
            accessCount: m.accessCount,
            status: m.status,
            validAt: m.validAt,
            invalidAt: m.invalidAt,
            supersededBy: m.supersededBy,
          );
        }
      }
    }

    return floored;
  }

  @override
  Future<int> expireSession(String sessionId, String component) async {
    var count = 0;
    final now = DateTime.now().toUtc();
    for (var i = 0; i < _memories.length; i++) {
      final m = _memories[i];
      if (m.isActive &&
          m.sessionId == sessionId &&
          m.component == component) {
        _memories[i] = StoredMemory(
          id: m.id,
          content: m.content,
          component: m.component,
          category: m.category,
          importance: m.importance,
          sessionId: m.sessionId,
          sourceEpisodeIds: m.sourceEpisodeIds,
          embedding: m.embedding,
          entityIds: m.entityIds,
          createdAt: m.createdAt,
          updatedAt: m.updatedAt,
          lastAccessed: m.lastAccessed,
          accessCount: m.accessCount,
          status: MemoryStatus.expired,
          validAt: m.validAt,
          invalidAt: now,
          supersededBy: m.supersededBy,
        );
        count++;
      }
    }
    return count;
  }

  @override
  Future<void> expireItem(String id) async {
    final index = _memories.indexWhere((m) => m.id == id);
    if (index == -1) return;
    final m = _memories[index];
    _memories[index] = StoredMemory(
      id: m.id,
      content: m.content,
      component: m.component,
      category: m.category,
      importance: m.importance,
      sessionId: m.sessionId,
      sourceEpisodeIds: m.sourceEpisodeIds,
      embedding: m.embedding,
      entityIds: m.entityIds,
      createdAt: m.createdAt,
      updatedAt: m.updatedAt,
      lastAccessed: m.lastAccessed,
      accessCount: m.accessCount,
      status: MemoryStatus.expired,
      validAt: m.validAt,
      invalidAt: DateTime.now().toUtc(),
      supersededBy: m.supersededBy,
    );
  }

  @override
  Future<void> supersede(String oldId, String newId) async {
    final index = _memories.indexWhere((m) => m.id == oldId);
    if (index == -1) return;
    final m = _memories[index];
    _memories[index] = StoredMemory(
      id: m.id,
      content: m.content,
      component: m.component,
      category: m.category,
      importance: m.importance,
      sessionId: m.sessionId,
      sourceEpisodeIds: m.sourceEpisodeIds,
      embedding: m.embedding,
      entityIds: m.entityIds,
      createdAt: m.createdAt,
      updatedAt: DateTime.now().toUtc(),
      lastAccessed: m.lastAccessed,
      accessCount: m.accessCount,
      status: MemoryStatus.superseded,
      validAt: m.validAt,
      invalidAt: m.invalidAt,
      supersededBy: newId,
    );
  }

  @override
  Future<int> activeItemCount(String component, {String? sessionId}) async {
    return _memories.where((m) {
      if (!m.isActive || m.component != component) return false;
      if (sessionId != null && m.sessionId != sessionId) return false;
      return true;
    }).length;
  }

  @override
  Future<List<StoredMemory>> activeItemsForSession(
    String sessionId,
    String component,
  ) async {
    return _memories
        .where(
          (m) =>
              m.isActive &&
              m.sessionId == sessionId &&
              m.component == component,
        )
        .toList();
  }

  @override
  Future<void> close() async {}

  // ── Testing helpers ───────────────────────────────────────────────────

  /// Total memories stored.
  int get length => _memories.length;

  /// Active memories.
  int get activeCount => _memories.where((m) => m.isActive).length;

  /// All entities.
  List<Entity> get entities => List.unmodifiable(_entities);

  /// All relationships.
  List<Relationship> get relationships => List.unmodifiable(_relationships);

  // ── Private ───────────────────────────────────────────────────────────

  static MemoryStatus _parseStatus(String s) {
    return MemoryStatus.values.firstWhere((v) => v.name == s);
  }

  /// Tokenizes text into lowercase word tokens for similarity matching.
  static Set<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 2)
        .toSet();
  }
}
