import 'dart:convert';
import 'dart:math' as math;

import 'package:souvenir/src/compaction_config.dart';
import 'package:souvenir/src/durable/durable_memory.dart';
import 'package:souvenir/src/durable/durable_memory_config.dart';
import 'package:souvenir/src/embedding_provider.dart';
import 'package:souvenir/src/engine.dart';
import 'package:souvenir/src/episode_store.dart';
import 'package:souvenir/src/in_memory_memory_store.dart';
import 'package:souvenir/src/models/episode.dart';
import 'package:souvenir/src/recall.dart';
import 'package:souvenir/src/stored_memory.dart';
import 'package:souvenir/src/vector_math.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Embedding provider that returns deterministic vectors.
class _FakeEmbeddings implements EmbeddingProvider {
  final Map<String, List<double>> _vectors;

  @override
  final int dimensions = 4;

  _FakeEmbeddings(this._vectors);

  @override
  Future<List<double>> embed(String text) async {
    if (_vectors.containsKey(text)) return _vectors[text]!;
    for (final entry in _vectors.entries) {
      if (text.toLowerCase().contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }
    return List.filled(dimensions, 0.0);
  }
}

DateTime _daysAgo(int days) =>
    DateTime.now().toUtc().subtract(Duration(days: days));

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // Tombstone pruning
  // ══════════════════════════════════════════════════════════════════════════

  group('Tombstone pruning', () {
    test('deletes expired memories past retention', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Expired 10 days ago (past 7d default retention).
      await store.insert(StoredMemory(
        content: 'Old expired memory should be deleted',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: _daysAgo(10),
      ));
      // Expired 3 days ago (within retention).
      await store.insert(StoredMemory(
        content: 'Recent expired memory should survive',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: _daysAgo(3),
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final report = await engine.compact();
      expect(report.expiredPruned, 1);

      final stats = await engine.stats();
      expect(stats.expiredMemories, 1);
    });

    test('deletes superseded memories past retention', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Superseded 40 days ago (past 30d default retention).
      await store.insert(StoredMemory(
        content: 'Old superseded memory should go',
        component: 'durable',
        category: 'fact',
        status: MemoryStatus.superseded,
        updatedAt: _daysAgo(40),
      ));
      // Superseded 10 days ago (within retention).
      await store.insert(StoredMemory(
        content: 'Recent superseded memory should stay',
        component: 'durable',
        category: 'fact',
        status: MemoryStatus.superseded,
        updatedAt: _daysAgo(10),
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final report = await engine.compact();
      expect(report.supersededPruned, 1);
    });

    test('deletes decayed memories past retention', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Decayed 20 days ago (past 14d default retention).
      await store.insert(StoredMemory(
        content: 'Old decayed memory should go',
        component: 'environmental',
        category: 'capability',
        status: MemoryStatus.decayed,
        updatedAt: _daysAgo(20),
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final report = await engine.compact();
      expect(report.decayedPruned, 1);
    });

    test('never deletes active memories', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      await store.insert(StoredMemory(
        content: 'Active memory is safe from compaction',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
        updatedAt: _daysAgo(100),
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final report = await engine.compact();
      expect(report.totalMemoriesPruned, 0);

      final stats = await engine.stats();
      expect(stats.activeMemories, 1);
    });

    test('custom retention periods are respected', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Expired 5 days ago.
      await store.insert(StoredMemory(
        content: 'Expired memory at 5 days',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: _daysAgo(5),
      ));

      // With default 7d retention: should NOT be pruned.
      final engine1 = Souvenir(components: [], store: store);
      await engine1.initialize();
      var report = await engine1.compact();
      expect(report.expiredPruned, 0);

      // With custom 3d retention: SHOULD be pruned.
      final engine2 = Souvenir(
        components: [],
        store: store,
        compactionConfig: CompactionConfig(
          expiredRetention: Duration(days: 3),
        ),
      );
      await engine2.initialize();
      report = await engine2.compact();
      expect(report.expiredPruned, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Episode cleanup
  // ══════════════════════════════════════════════════════════════════════════

  group('Episode cleanup', () {
    test('deletes consolidated episodes past retention', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();

      // Insert and consolidate an old episode.
      final oldEp = Episode(
        sessionId: 'ses1',
        type: EpisodeType.observation,
        content: 'Old episode content',
        timestamp: _daysAgo(40),
      );
      await episodeStore.insert([oldEp]);
      await episodeStore.markConsolidated([oldEp]);

      // Insert and consolidate a recent episode.
      final recentEp = Episode(
        sessionId: 'ses1',
        type: EpisodeType.observation,
        content: 'Recent episode content',
        timestamp: _daysAgo(5),
      );
      await episodeStore.insert([recentEp]);
      await episodeStore.markConsolidated([recentEp]);

      final engine = Souvenir(
        components: [],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.episodesPruned, 1);
    });

    test('never deletes unconsolidated episodes', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();

      final ep = Episode(
        sessionId: 'ses1',
        type: EpisodeType.observation,
        content: 'Unconsolidated but old',
        timestamp: _daysAgo(100),
      );
      await episodeStore.insert([ep]);

      final engine = Souvenir(
        components: [],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.episodesPruned, 0);
      expect(episodeStore.length, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Near-duplicate compaction
  // ══════════════════════════════════════════════════════════════════════════

  group('Near-duplicate compaction', () {
    test('merges similar memories above threshold', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Two nearly identical vectors (cosine similarity ~1.0).
      final vec1 = [0.9, 0.1, 0.0, 0.0];
      final vec2 = [0.89, 0.11, 0.0, 0.0];

      final mem1 = StoredMemory(
        content: 'User prefers Dart for backend work',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
        embedding: vec1,
        entityIds: ['e1'],
        sourceEpisodeIds: ['ep1'],
      );
      final mem2 = StoredMemory(
        content: 'User likes Dart for server-side development',
        component: 'durable',
        category: 'fact',
        importance: 0.6,
        embedding: vec2,
        entityIds: ['e2'],
        sourceEpisodeIds: ['ep2'],
      );
      await store.insert(mem1);
      await store.insert(mem2);

      // Verify they're above the threshold.
      expect(cosineSimilarity(vec1, vec2), greaterThan(0.92));

      final embeddings = _FakeEmbeddings({});
      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: embeddings,
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.duplicatesMerged, 1);

      // Higher-importance memory (mem1) should survive.
      final stats = await engine.stats();
      expect(stats.activeMemories, 1);
      expect(stats.supersededMemories, 1);

      // Survivor should have unioned entity IDs and source IDs.
      final active = await store.loadActiveWithEmbeddings();
      expect(active, hasLength(1));
      expect(active.first.id, mem1.id);
      expect(active.first.entityIds, containsAll(['e1', 'e2']));
      expect(active.first.sourceEpisodeIds, containsAll(['ep1', 'ep2']));
    });

    test('does not merge memories below threshold', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Two very different vectors.
      final vec1 = [1.0, 0.0, 0.0, 0.0];
      final vec2 = [0.0, 0.0, 1.0, 0.0];

      await store.insert(StoredMemory(
        content: 'User prefers Dart',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
        embedding: vec1,
      ));
      await store.insert(StoredMemory(
        content: 'Project uses PostgreSQL',
        component: 'durable',
        category: 'fact',
        importance: 0.7,
        embedding: vec2,
      ));

      expect(cosineSimilarity(vec1, vec2), lessThan(0.92));

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({}),
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.duplicatesMerged, 0);

      final stats = await engine.stats();
      expect(stats.activeMemories, 2);
    });

    test('skipped without embeddings provider', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      await store.insert(StoredMemory(
        content: 'Memory one',
        component: 'durable',
        category: 'fact',
        embedding: [0.9, 0.1, 0.0, 0.0],
      ));
      await store.insert(StoredMemory(
        content: 'Memory two',
        component: 'durable',
        category: 'fact',
        embedding: [0.89, 0.11, 0.0, 0.0],
      ));

      final engine = Souvenir(
        components: [],
        store: store,
        // No embeddings provider.
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.duplicatesMerged, 0);
    });

    test('skipped when deduplication threshold is null', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      await store.insert(StoredMemory(
        content: 'Memory one',
        component: 'durable',
        category: 'fact',
        embedding: [0.9, 0.1, 0.0, 0.0],
      ));
      await store.insert(StoredMemory(
        content: 'Memory two',
        component: 'durable',
        category: 'fact',
        embedding: [0.89, 0.11, 0.0, 0.0],
      ));

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({}),
        compactionConfig: CompactionConfig(deduplicationThreshold: null),
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.duplicatesMerged, 0);
    });

    test('higher-scored memory survives', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final vec = [0.9, 0.1, 0.0, 0.0];

      // mem1 has lower importance but higher access count.
      final mem1 = StoredMemory(
        content: 'Low importance high access',
        component: 'durable',
        category: 'fact',
        importance: 0.3,
        accessCount: 100,
        embedding: vec,
      );
      // mem2 has higher importance but no access.
      final mem2 = StoredMemory(
        content: 'High importance no access',
        component: 'durable',
        category: 'fact',
        importance: 0.9,
        accessCount: 0,
        embedding: vec,
      );
      await store.insert(mem1);
      await store.insert(mem2);

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({}),
      );
      await engine.initialize();

      await engine.compact();

      final active = await store.loadActiveWithEmbeddings();
      expect(active, hasLength(1));
      // mem2 has score = 0.9 * 1.0 = 0.9
      // mem1 has score = 0.3 * (1 + log(101) * 0.1) ≈ 0.3 * 1.46 ≈ 0.44
      // mem2 should survive.
      expect(active.first.id, mem2.id);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Entity graph pruning
  // ══════════════════════════════════════════════════════════════════════════

  group('Entity graph pruning', () {
    test('removes orphaned entities', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final referencedEntity = Entity(name: 'Dart', type: 'language');
      final orphanedEntity = Entity(name: 'Forgotten', type: 'concept');
      await store.upsertEntity(referencedEntity);
      await store.upsertEntity(orphanedEntity);

      await store.insert(StoredMemory(
        content: 'User prefers Dart programming language',
        component: 'durable',
        category: 'fact',
        entityIds: [referencedEntity.id],
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final report = await engine.compact();
      expect(report.entitiesRemoved, 1);

      // Referenced entity survives.
      final entities = await store.findEntitiesByName('Dart');
      expect(entities, hasLength(1));

      // Orphaned entity is gone.
      final orphans = await store.findEntitiesByName('Forgotten');
      expect(orphans, isEmpty);
    });

    test('removes orphaned relationships', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final e1 = Entity(name: 'Dart', type: 'language');
      final e2 = Entity(name: 'Flutter', type: 'framework');
      final e3 = Entity(name: 'Orphan', type: 'concept');
      await store.upsertEntity(e1);
      await store.upsertEntity(e2);
      await store.upsertEntity(e3);

      // Relationship between two referenced entities.
      await store.upsertRelationship(Relationship(
        fromEntity: e1.id,
        toEntity: e2.id,
        relation: 'used_by',
      ));
      // Relationship involving an orphaned entity.
      await store.upsertRelationship(Relationship(
        fromEntity: e1.id,
        toEntity: e3.id,
        relation: 'related_to',
      ));

      await store.insert(StoredMemory(
        content: 'Dart is used by Flutter framework',
        component: 'durable',
        category: 'fact',
        entityIds: [e1.id, e2.id],
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final report = await engine.compact();
      // e3 is orphaned → its relationship gets removed, then e3 gets removed.
      expect(report.relationshipsRemoved, 1);
      expect(report.entitiesRemoved, 1);

      // Surviving relationship is intact.
      final rels = await store.findRelationshipsForEntity(e1.id);
      expect(rels, hasLength(1));
      expect(rels.first.toEntity, e2.id);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Stats
  // ══════════════════════════════════════════════════════════════════════════

  group('Stats', () {
    test('returns correct counts by status and component', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      await store.insert(StoredMemory(
        content: 'Active task memory here',
        component: 'task',
        category: 'goal',
      ));
      await store.insert(StoredMemory(
        content: 'Active durable memory here',
        component: 'durable',
        category: 'fact',
      ));
      await store.insert(StoredMemory(
        content: 'Another active durable memory',
        component: 'durable',
        category: 'fact',
      ));
      await store.insert(StoredMemory(
        content: 'Expired memory goes here',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
      ));
      await store.insert(StoredMemory(
        content: 'Superseded memory goes here',
        component: 'durable',
        category: 'fact',
        status: MemoryStatus.superseded,
      ));
      await store.insert(StoredMemory(
        content: 'Decayed memory goes here',
        component: 'environmental',
        category: 'capability',
        status: MemoryStatus.decayed,
      ));
      await store.insert(StoredMemory(
        content: 'Embedded memory has vector',
        component: 'durable',
        category: 'fact',
        embedding: [0.1, 0.2, 0.3],
      ));

      await store.upsertEntity(Entity(name: 'Dart', type: 'language'));
      await store.upsertEntity(Entity(name: 'Flutter', type: 'framework'));
      await store.upsertRelationship(Relationship(
        fromEntity: 'e1',
        toEntity: 'e2',
        relation: 'uses',
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final stats = await engine.stats();
      expect(stats.totalMemories, 7);
      expect(stats.activeMemories, 4);
      expect(stats.expiredMemories, 1);
      expect(stats.supersededMemories, 1);
      expect(stats.decayedMemories, 1);
      expect(stats.embeddedMemories, 1);
      expect(stats.entities, 2);
      expect(stats.relationships, 1);
      expect(stats.activeByComponent['task'], 1);
      expect(stats.activeByComponent['durable'], 3);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Integration
  // ══════════════════════════════════════════════════════════════════════════

  group('Integration', () {
    test('full compact cycle with mixed data', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();
      await store.initialize();

      // Active memories.
      await store.insert(StoredMemory(
        content: 'Active memory that should survive compaction',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));

      // Old tombstoned memories.
      await store.insert(StoredMemory(
        content: 'Old expired memory for cleanup',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: _daysAgo(10),
      ));
      await store.insert(StoredMemory(
        content: 'Old superseded memory for cleanup',
        component: 'durable',
        category: 'fact',
        status: MemoryStatus.superseded,
        updatedAt: _daysAgo(40),
      ));
      await store.insert(StoredMemory(
        content: 'Old decayed memory for cleanup',
        component: 'environmental',
        category: 'pattern',
        status: MemoryStatus.decayed,
        updatedAt: _daysAgo(20),
      ));

      // Orphaned entity.
      final orphan = Entity(name: 'Orphan', type: 'concept');
      await store.upsertEntity(orphan);

      // Old consolidated episode.
      final oldEp = Episode(
        sessionId: 'ses1',
        type: EpisodeType.observation,
        content: 'Old episode',
        timestamp: _daysAgo(40),
      );
      await episodeStore.insert([oldEp]);
      await episodeStore.markConsolidated([oldEp]);

      final engine = Souvenir(
        components: [],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.expiredPruned, 1);
      expect(report.supersededPruned, 1);
      expect(report.decayedPruned, 1);
      expect(report.episodesPruned, 1);
      expect(report.entitiesRemoved, 1);
      expect(report.totalMemoriesPruned, 3);

      final stats = await engine.stats();
      expect(stats.activeMemories, 1);
      expect(stats.expiredMemories, 0);
      expect(stats.supersededMemories, 0);
      expect(stats.decayedMemories, 0);
      expect(stats.entities, 0);
    });

    test('idempotent: second compact returns all zeros', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      await store.insert(StoredMemory(
        content: 'Old expired memory to prune',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: _daysAgo(10),
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final first = await engine.compact();
      expect(first.expiredPruned, 1);

      final second = await engine.compact();
      expect(second.expiredPruned, 0);
      expect(second.supersededPruned, 0);
      expect(second.decayedPruned, 0);
      expect(second.episodesPruned, 0);
      expect(second.duplicatesMerged, 0);
      expect(second.entitiesRemoved, 0);
      expect(second.relationshipsRemoved, 0);
    });

    test('compact throws before initialization', () async {
      final store = InMemoryMemoryStore();
      final engine = Souvenir(components: [], store: store);

      expect(() => engine.compact(), throwsStateError);
    });

    test('stats throws before initialization', () async {
      final store = InMemoryMemoryStore();
      final engine = Souvenir(components: [], store: store);

      expect(() => engine.stats(), throwsStateError);
    });

    test('compact is safe on empty store', () async {
      final store = InMemoryMemoryStore();
      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final report = await engine.compact();
      expect(report.totalMemoriesPruned, 0);
      expect(report.episodesPruned, 0);
      expect(report.duplicatesMerged, 0);
      expect(report.entitiesRemoved, 0);
      expect(report.relationshipsRemoved, 0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // vector_math
  // ══════════════════════════════════════════════════════════════════════════

  group('cosineSimilarity', () {
    test('identical vectors return 1.0', () {
      final v = [1.0, 0.0, 0.0];
      expect(cosineSimilarity(v, v), closeTo(1.0, 0.001));
    });

    test('orthogonal vectors return 0.0', () {
      expect(
        cosineSimilarity([1.0, 0.0], [0.0, 1.0]),
        closeTo(0.0, 0.001),
      );
    });

    test('mismatched lengths return 0.0', () {
      expect(cosineSimilarity([1.0], [1.0, 0.0]), 0.0);
    });

    test('empty vectors return 0.0', () {
      expect(cosineSimilarity([], []), 0.0);
    });

    test('zero vectors return 0.0', () {
      expect(cosineSimilarity([0.0, 0.0], [0.0, 0.0]), 0.0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Post-compaction recall consistency
  // ══════════════════════════════════════════════════════════════════════════

  group('Post-compaction recall', () {
    test('recall returns correct results after tombstone pruning', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Active memory.
      await store.insert(StoredMemory(
        content: 'User prefers Dart for backend development',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));
      // Expired memory (should not appear in recall, then gets pruned).
      await store.insert(StoredMemory(
        content: 'Old task about Dart CLI tooling',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: _daysAgo(10),
      ));

      final engine = Souvenir(
        components: [],
        store: store,
        recallConfig: RecallConfig(),
      );
      await engine.initialize();

      // Recall before compaction.
      var result = await engine.recall('Dart');
      expect(result.items, hasLength(1));
      expect(result.items.first.content, contains('backend'));

      // Compact — prunes the expired tombstone.
      final report = await engine.compact();
      expect(report.expiredPruned, 1);

      // Recall after compaction — same result, no ghost entries.
      result = await engine.recall('Dart');
      expect(result.items, hasLength(1));
      expect(result.items.first.content, contains('backend'));
    });

    test('recall works after entity graph pruning', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final dartEntity = Entity(name: 'Dart', type: 'language');
      final orphanEntity = Entity(name: 'OldThing', type: 'concept');
      await store.upsertEntity(dartEntity);
      await store.upsertEntity(orphanEntity);
      await store.upsertRelationship(Relationship(
        fromEntity: dartEntity.id,
        toEntity: orphanEntity.id,
        relation: 'related_to',
      ));

      await store.insert(StoredMemory(
        content: 'Dart is the primary programming language',
        component: 'durable',
        category: 'fact',
        importance: 0.9,
        entityIds: [dartEntity.id],
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      // Compact prunes orphanEntity and its relationship.
      final report = await engine.compact();
      expect(report.entitiesRemoved, 1);
      expect(report.relationshipsRemoved, 1);

      // Recall still works — entity graph signal still present for Dart.
      final result = await engine.recall('Dart');
      expect(result.items, hasLength(1));
      expect(result.items.first.entitySignal, greaterThan(0));
    });

    test('recall works after near-duplicate compaction', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final vec = [0.9, 0.1, 0.0, 0.0];
      await store.insert(StoredMemory(
        content: 'User prefers Dart for backend work',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
        embedding: vec,
      ));
      await store.insert(StoredMemory(
        content: 'User likes Dart for server-side code',
        component: 'durable',
        category: 'fact',
        importance: 0.6,
        embedding: vec,
      ));

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({'dart': vec}),
      );
      await engine.initialize();

      // Before compaction: 2 results.
      var result = await engine.recall('Dart');
      expect(result.items, hasLength(2));

      // Compact merges duplicates.
      final report = await engine.compact();
      expect(report.duplicatesMerged, 1);

      // After compaction: 1 result (the survivor).
      result = await engine.recall('Dart');
      expect(result.items, hasLength(1));
      expect(result.items.first.content, contains('backend'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Durable memory decay floor threshold
  // ══════════════════════════════════════════════════════════════════════════

  group('Durable decay floor', () {
    test('marks low-importance durable memories as decayed', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Insert a durable memory with low importance, aged past decay period.
      final old = DateTime.now().toUtc().subtract(const Duration(days: 100));
      await store.insert(StoredMemory(
        content: 'Very old low importance durable fact',
        component: 'durable',
        category: 'fact',
        importance: 0.04, // Below 0.05 threshold after any decay.
        updatedAt: old,
      ));

      final durable = DurableMemory(
        store: store,
        config: DurableMemoryConfig(
          importanceDecayRate: 0.97,
          decayInactivePeriod: const Duration(days: 90),
          decayFloorThreshold: 0.05,
        ),
      );
      await durable.initialize();

      // Consolidate with empty episodes — only decay runs.
      final llm = (String s, String u) async => jsonEncode({
            'facts': <dynamic>[],
            'relationships': <dynamic>[],
          });
      final report = await durable.consolidate([], llm);

      // 0.04 * 0.97 = 0.0388 < 0.05 → marked decayed.
      expect(report.itemsDecayed, 1);
      expect(await store.activeItemCount('durable'), 0);
    });

    test('preserves durable memories above floor', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final old = DateTime.now().toUtc().subtract(const Duration(days: 100));
      await store.insert(StoredMemory(
        content: 'Important durable fact stays active',
        component: 'durable',
        category: 'fact',
        importance: 0.5,
        updatedAt: old,
      ));

      final durable = DurableMemory(
        store: store,
        config: DurableMemoryConfig(
          importanceDecayRate: 0.97,
          decayInactivePeriod: const Duration(days: 90),
          decayFloorThreshold: 0.05,
        ),
      );
      await durable.initialize();

      final llm = (String s, String u) async => jsonEncode({
            'facts': <dynamic>[],
            'relationships': <dynamic>[],
          });
      final report = await durable.consolidate([], llm);

      // 0.5 * 0.97 = 0.485 > 0.05 → stays active.
      expect(report.itemsDecayed, 0);
      expect(await store.activeItemCount('durable'), 1);
    });

    test('null floor disables decay marking', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final old = DateTime.now().toUtc().subtract(const Duration(days: 100));
      await store.insert(StoredMemory(
        content: 'Tiny importance but no floor check',
        component: 'durable',
        category: 'fact',
        importance: 0.01,
        updatedAt: old,
      ));

      final durable = DurableMemory(
        store: store,
        config: DurableMemoryConfig(
          importanceDecayRate: 0.97,
          decayInactivePeriod: const Duration(days: 90),
          decayFloorThreshold: null, // Disabled.
        ),
      );
      await durable.initialize();

      final llm = (String s, String u) async => jsonEncode({
            'facts': <dynamic>[],
            'relationships': <dynamic>[],
          });
      final report = await durable.consolidate([], llm);

      // No floor → never marked decayed, just decayed in importance.
      expect(report.itemsDecayed, 0);
      expect(await store.activeItemCount('durable'), 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Scale: near-duplicate detection under volume
  // ══════════════════════════════════════════════════════════════════════════

  group('Scale', () {
    test('near-duplicate detection handles 200 memories', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      final rng = math.Random(42);

      // Generate 200 memories with random 8-dim embeddings.
      for (var i = 0; i < 200; i++) {
        final vec = List.generate(8, (_) => rng.nextDouble());
        await store.insert(StoredMemory(
          content: 'Memory item number $i about various topics',
          component: 'durable',
          category: 'fact',
          importance: 0.3 + rng.nextDouble() * 0.7,
          embedding: vec,
        ));
      }

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({}),
        compactionConfig: CompactionConfig(deduplicationThreshold: 0.99),
      );
      await engine.initialize();

      // Should complete without error in reasonable time.
      final stopwatch = Stopwatch()..start();
      final report = await engine.compact();
      stopwatch.stop();

      // With random vectors and 0.99 threshold, very few (if any) merges.
      expect(report.duplicatesMerged, lessThan(10));
      // Should complete in under 5 seconds for 200 items (O(n^2) = 40k pairs).
      expect(stopwatch.elapsedMilliseconds, lessThan(5000));

      final stats = await engine.stats();
      expect(
        stats.activeMemories,
        200 - report.duplicatesMerged,
      );
    });

    test('duplicate cluster collapses correctly', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // 10 nearly identical memories — all should collapse to 1 survivor.
      final vec = [0.9, 0.1, 0.0, 0.0];
      for (var i = 0; i < 10; i++) {
        await store.insert(StoredMemory(
          content: 'User prefers Dart variant $i',
          component: 'durable',
          category: 'fact',
          importance: 0.5 + i * 0.05,
          embedding: vec,
        ));
      }

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({}),
      );
      await engine.initialize();

      final report = await engine.compact();
      expect(report.duplicatesMerged, 9);

      final stats = await engine.stats();
      expect(stats.activeMemories, 1);

      // Survivor should be the highest-importance one (0.5 + 9*0.05 = 0.95).
      final active = await store.loadActiveWithEmbeddings();
      expect(active.first.importance, closeTo(0.95, 0.01));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Transitive duplicate chains
  // ══════════════════════════════════════════════════════════════════════════

  group('Transitive chains', () {
    test('A~B and B~C but not A~C: only direct pairs merge', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // Three vectors at 20° rotations: adjacent pairs similar, endpoints not.
      // A = [1.0, 0.0, 0, 0]
      // B = [cos(20°), sin(20°), 0, 0]  (sim(A,B) ≈ 0.94)
      // C = [cos(40°), sin(40°), 0, 0]  (sim(B,C) ≈ 0.94, sim(A,C) ≈ 0.77)
      final vecA = [1.0, 0.0, 0.0, 0.0];
      final vecB = [0.9397, 0.342, 0.0, 0.0];
      final vecC = [0.766, 0.6428, 0.0, 0.0];

      // Verify similarities.
      expect(cosineSimilarity(vecA, vecB), greaterThan(0.92));
      expect(cosineSimilarity(vecB, vecC), greaterThan(0.92));
      expect(cosineSimilarity(vecA, vecC), lessThan(0.92));

      final memA = StoredMemory(
        content: 'Memory A about topic alpha',
        component: 'durable',
        category: 'fact',
        importance: 0.9, // Highest — will survive.
        embedding: vecA,
      );
      final memB = StoredMemory(
        content: 'Memory B about topic beta',
        component: 'durable',
        category: 'fact',
        importance: 0.5,
        embedding: vecB,
      );
      final memC = StoredMemory(
        content: 'Memory C about topic gamma',
        component: 'durable',
        category: 'fact',
        importance: 0.7,
        embedding: vecC,
      );
      await store.insert(memA);
      await store.insert(memB);
      await store.insert(memC);

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({}),
      );
      await engine.initialize();

      final report = await engine.compact();

      // Sorted by score: A(0.9), C(0.7), B(0.5).
      // A vs C: sim ≈ 0.50 < 0.92 → no merge.
      // A vs B: sim ≈ 0.93 > 0.92 → B superseded by A.
      // C vs B: B already superseded, skip.
      // Result: 1 merge (B into A), C survives independently.
      expect(report.duplicatesMerged, 1);

      final stats = await engine.stats();
      expect(stats.activeMemories, 2);

      // A and C should be the survivors.
      final active = await store.loadActiveWithEmbeddings();
      final activeIds = active.map((m) => m.id).toSet();
      expect(activeIds, contains(memA.id));
      expect(activeIds, contains(memC.id));
      expect(activeIds, isNot(contains(memB.id)));
    });

    test('chain does not cascade: superseded items are skipped', () async {
      final store = InMemoryMemoryStore();
      await store.initialize();

      // All identical vectors — forms a full clique.
      final vec = [1.0, 0.0, 0.0, 0.0];
      final mem1 = StoredMemory(
        content: 'Highest importance memory survives',
        component: 'durable',
        category: 'fact',
        importance: 0.9,
        embedding: vec,
      );
      final mem2 = StoredMemory(
        content: 'Medium importance gets superseded',
        component: 'durable',
        category: 'fact',
        importance: 0.6,
        embedding: vec,
      );
      final mem3 = StoredMemory(
        content: 'Low importance gets superseded',
        component: 'durable',
        category: 'fact',
        importance: 0.3,
        embedding: vec,
      );
      await store.insert(mem1);
      await store.insert(mem2);
      await store.insert(mem3);

      final engine = Souvenir(
        components: [],
        store: store,
        embeddings: _FakeEmbeddings({}),
      );
      await engine.initialize();

      final report = await engine.compact();
      // mem1 survives, mem2 and mem3 both superseded.
      expect(report.duplicatesMerged, 2);

      final active = await store.loadActiveWithEmbeddings();
      expect(active, hasLength(1));
      expect(active.first.id, mem1.id);
    });
  });
}
