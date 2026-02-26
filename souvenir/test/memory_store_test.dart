import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

import 'package:souvenir/src/stored_memory.dart';
import 'package:souvenir/src/memory_store.dart';
import 'package:souvenir/src/in_memory_memory_store.dart';
import 'package:souvenir/src/sqlite_memory_store.dart';

void main() {
  // Run the same test suite against both implementations.
  group('InMemoryMemoryStore', () {
    _memoryStoreTests(() async => InMemoryMemoryStore());
  });

  group('SqliteMemoryStore', () {
    _memoryStoreTests(() async {
      final db = sqlite3.sqlite3.openInMemory();
      final store = SqliteMemoryStore(db);
      await store.initialize();
      return store;
    });
  });

  group('SqliteMemoryStore (prefixed)', () {
    _memoryStoreTests(() async {
      final db = sqlite3.sqlite3.openInMemory();
      final store = SqliteMemoryStore(db, prefix: 'agent1_');
      await store.initialize();
      return store;
    });
  });
}

void _memoryStoreTests(Future<MemoryStore> Function() createStore) {
  late MemoryStore store;

  setUp(() async {
    store = await createStore();
    await store.initialize();
  });

  tearDown(() async {
    await store.close();
  });

  // ── Insert and basic retrieval ──────────────────────────────────────

  group('insert and retrieve', () {
    test('inserts and retrieves via findSimilar', () async {
      final mem = StoredMemory(
        content: 'User prefers Dart programming',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      );

      await store.insert(mem);

      final similar = await store.findSimilar(
        'Dart programming preferences',
        'durable',
      );

      expect(similar, hasLength(1));
      expect(similar.first.id, equals(mem.id));
      expect(similar.first.content, equals('User prefers Dart programming'));
      expect(similar.first.component, equals('durable'));
      expect(similar.first.category, equals('fact'));
      expect(similar.first.importance, equals(0.8));
    });

    test('findSimilar scoped to component', () async {
      await store.insert(StoredMemory(
        content: 'User prefers Dart functions',
        component: 'task',
        category: 'goal',
      ));
      await store.insert(StoredMemory(
        content: 'User prefers Dart functions over classes',
        component: 'durable',
        category: 'fact',
      ));

      final taskSimilar = await store.findSimilar(
        'Dart functions',
        'task',
      );
      expect(taskSimilar, hasLength(1));
      expect(taskSimilar.first.component, equals('task'));

      final durableSimilar = await store.findSimilar(
        'Dart functions',
        'durable',
      );
      expect(durableSimilar, hasLength(1));
      expect(durableSimilar.first.component, equals('durable'));
    });

    test('findSimilar scoped to category', () async {
      await store.insert(StoredMemory(
        content: 'User wants to build a server',
        component: 'task',
        category: 'goal',
        sessionId: 'ses1',
      ));
      await store.insert(StoredMemory(
        content: 'User decided to build with Dart',
        component: 'task',
        category: 'decision',
        sessionId: 'ses1',
      ));

      final goals = await store.findSimilar(
        'build server',
        'task',
        category: 'goal',
        sessionId: 'ses1',
      );
      expect(goals, hasLength(1));
      expect(goals.first.category, equals('goal'));
    });

    test('findSimilar scoped to session', () async {
      await store.insert(StoredMemory(
        content: 'User wants to build a server',
        component: 'task',
        category: 'goal',
        sessionId: 'ses1',
      ));
      await store.insert(StoredMemory(
        content: 'User wants to build a server quickly',
        component: 'task',
        category: 'goal',
        sessionId: 'ses2',
      ));

      final ses1 = await store.findSimilar(
        'build server',
        'task',
        sessionId: 'ses1',
      );
      expect(ses1, hasLength(1));
      expect(ses1.first.sessionId, equals('ses1'));
    });

    test('findSimilar excludes inactive memories', () async {
      await store.insert(StoredMemory(
        content: 'User wants to build a server',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
      ));

      final results = await store.findSimilar('build server', 'task');
      expect(results, isEmpty);
    });
  });

  // ── FTS search ──────────────────────────────────────────────────────

  group('searchFts', () {
    test('returns matches ranked by relevance', () async {
      await store.insert(StoredMemory(
        content: 'User finds rabbits cute and enjoys learning about them',
        component: 'durable',
        category: 'fact',
        importance: 0.4,
      ));
      await store.insert(StoredMemory(
        content: 'User is interested in Dart programming',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));

      final results = await store.searchFts('rabbits cute');
      expect(results, isNotEmpty);
      expect(results.first.memory.content, contains('rabbits'));
      expect(results.first.score, greaterThan(0));
    });

    test('returns empty for no matches', () async {
      await store.insert(StoredMemory(
        content: 'User is interested in Dart programming',
        component: 'durable',
        category: 'fact',
      ));

      final results = await store.searchFts('quantum physics');
      expect(results, isEmpty);
    });

    test('excludes expired memories', () async {
      await store.insert(StoredMemory(
        content: 'User loves Dart programming',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
      ));

      final results = await store.searchFts('Dart programming');
      expect(results, isEmpty);
    });

    test('excludes temporally invalid memories', () async {
      final pastDate = DateTime.now().toUtc().subtract(
        const Duration(hours: 1),
      );
      await store.insert(StoredMemory(
        content: 'User loves Dart programming',
        component: 'task',
        category: 'goal',
        invalidAt: pastDate,
      ));

      final results = await store.searchFts('Dart programming');
      expect(results, isEmpty);
    });

    test('searches across all components', () async {
      await store.insert(StoredMemory(
        content: 'User wants to write Dart functions',
        component: 'task',
        category: 'goal',
      ));
      await store.insert(StoredMemory(
        content: 'User prefers Dart over Python',
        component: 'durable',
        category: 'fact',
      ));
      await store.insert(StoredMemory(
        content: 'Agent can provide Dart code examples',
        component: 'environmental',
        category: 'capability',
      ));

      final results = await store.searchFts('Dart');
      expect(results, hasLength(3));
    });
  });

  // ── Update ──────────────────────────────────────────────────────────

  group('update', () {
    test('updates content', () async {
      final mem = StoredMemory(
        content: 'Original content',
        component: 'durable',
        category: 'fact',
      );
      await store.insert(mem);

      await store.update(mem.id, content: 'Updated content');

      final results = await store.findSimilar('Updated content', 'durable');
      expect(results, hasLength(1));
      expect(results.first.content, equals('Updated content'));
    });

    test('updates importance', () async {
      final mem = StoredMemory(
        content: 'Some important fact about coding',
        component: 'durable',
        category: 'fact',
        importance: 0.5,
      );
      await store.insert(mem);

      await store.update(mem.id, importance: 0.9);

      final results = await store.findSimilar('important fact coding', 'durable');
      expect(results, hasLength(1));
      expect(results.first.importance, equals(0.9));
    });

    test('updates embedding', () async {
      final mem = StoredMemory(
        content: 'User finds rabbits cute',
        component: 'durable',
        category: 'fact',
      );
      await store.insert(mem);

      final embedding = List<double>.generate(384, (i) => i * 0.001);
      await store.update(mem.id, embedding: embedding);

      final withEmbeddings = await store.loadActiveWithEmbeddings();
      expect(withEmbeddings, hasLength(1));
      expect(withEmbeddings.first.embedding, isNotNull);
      expect(withEmbeddings.first.embedding!.length, equals(384));
    });
  });

  // ── Embeddings ──────────────────────────────────────────────────────

  group('embeddings', () {
    test('loadActiveWithEmbeddings excludes unembedded', () async {
      await store.insert(StoredMemory(
        content: 'Has embedding',
        component: 'durable',
        category: 'fact',
        embedding: [0.1, 0.2, 0.3],
      ));
      await store.insert(StoredMemory(
        content: 'No embedding',
        component: 'durable',
        category: 'fact',
      ));

      final results = await store.loadActiveWithEmbeddings();
      expect(results, hasLength(1));
      expect(results.first.content, equals('Has embedding'));
    });

    test('findUnembeddedMemories returns only unembedded active', () async {
      await store.insert(StoredMemory(
        content: 'Has embedding',
        component: 'durable',
        category: 'fact',
        embedding: [0.1, 0.2, 0.3],
      ));
      await store.insert(StoredMemory(
        content: 'No embedding active',
        component: 'task',
        category: 'goal',
      ));
      await store.insert(StoredMemory(
        content: 'No embedding expired',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
      ));

      final results = await store.findUnembeddedMemories();
      expect(results, hasLength(1));
      expect(results.first.content, equals('No embedding active'));
    });

    test('embedding round-trip preserves values', () async {
      final embedding = [0.123, -0.456, 0.789, 1.0, -1.0];
      final mem = StoredMemory(
        content: 'Test embedding round trip',
        component: 'durable',
        category: 'fact',
        embedding: embedding,
      );
      await store.insert(mem);

      final results = await store.loadActiveWithEmbeddings();
      expect(results, hasLength(1));
      for (var i = 0; i < embedding.length; i++) {
        expect(
          results.first.embedding![i],
          closeTo(embedding[i], 0.001),
        );
      }
    });
  });

  // ── Entity graph ──────────────────────────────────────────────────

  group('entity graph', () {
    test('upsert and find entities by name', () async {
      await store.upsertEntity(Entity(name: 'Dart', type: 'language'));
      await store.upsertEntity(Entity(name: 'rabbits', type: 'animal'));

      final results = await store.findEntitiesByName('Dart language');
      expect(results, hasLength(1));
      expect(results.first.name, equals('Dart'));
    });

    test('upsert entity updates type on conflict', () async {
      final entity = Entity(name: 'Dart', type: 'language');
      await store.upsertEntity(entity);
      await store.upsertEntity(Entity(
        id: entity.id,
        name: 'Dart',
        type: 'framework',
      ));

      final results = await store.findEntitiesByName('Dart');
      expect(results, hasLength(1));
      expect(results.first.type, equals('framework'));
    });

    test('upsert and find relationships', () async {
      final dart = Entity(name: 'Dart', type: 'language');
      final flutter = Entity(name: 'Flutter', type: 'framework');
      await store.upsertEntity(dart);
      await store.upsertEntity(flutter);

      await store.upsertRelationship(Relationship(
        fromEntity: dart.id,
        toEntity: flutter.id,
        relation: 'used_by',
        confidence: 0.9,
      ));

      final rels = await store.findRelationshipsForEntity(dart.id);
      expect(rels, hasLength(1));
      expect(rels.first.relation, equals('used_by'));
      expect(rels.first.confidence, equals(0.9));
    });

    test('findMemoriesByEntityIds returns memories with matching entities',
        () async {
      final entity = Entity(name: 'Dart', type: 'language');
      await store.upsertEntity(entity);

      await store.insert(StoredMemory(
        content: 'User prefers Dart programming',
        component: 'durable',
        category: 'fact',
        entityIds: [entity.id],
      ));
      await store.insert(StoredMemory(
        content: 'User finds rabbits cute',
        component: 'durable',
        category: 'fact',
        entityIds: [],
      ));

      final results = await store.findMemoriesByEntityIds([entity.id]);
      expect(results, hasLength(1));
      expect(results.first.content, contains('Dart'));
    });
  });

  // ── Lifecycle operations ──────────────────────────────────────────

  group('lifecycle', () {
    test('updateAccessStats bumps count and timestamp', () async {
      final mem = StoredMemory(
        content: 'Some fact about coding in Dart',
        component: 'durable',
        category: 'fact',
      );
      await store.insert(mem);

      await store.updateAccessStats([mem.id]);

      final results = await store.findSimilar('fact about coding', 'durable');
      expect(results, hasLength(1));
      expect(results.first.accessCount, equals(1));
      expect(results.first.lastAccessed, isNotNull);
    });

    test('expireSession expires all session items', () async {
      await store.insert(StoredMemory(
        content: 'Task one for session',
        component: 'task',
        category: 'goal',
        sessionId: 'ses1',
      ));
      await store.insert(StoredMemory(
        content: 'Task two for session',
        component: 'task',
        category: 'decision',
        sessionId: 'ses1',
      ));
      await store.insert(StoredMemory(
        content: 'Task from other session',
        component: 'task',
        category: 'goal',
        sessionId: 'ses2',
      ));

      final expired = await store.expireSession('ses1', 'task');
      expect(expired, equals(2));

      final active = await store.activeItemCount('task');
      expect(active, equals(1));
    });

    test('expireItem expires a single memory', () async {
      final mem = StoredMemory(
        content: 'Will be expired soon enough',
        component: 'task',
        category: 'goal',
        sessionId: 'ses1',
      );
      await store.insert(mem);

      await store.expireItem(mem.id);

      final active = await store.activeItemCount('task');
      expect(active, equals(0));
    });

    test('supersede marks old memory', () async {
      final old = StoredMemory(
        content: 'Old fact about something',
        component: 'durable',
        category: 'fact',
      );
      final replacement = StoredMemory(
        content: 'New fact about something',
        component: 'durable',
        category: 'fact',
      );
      await store.insert(old);
      await store.insert(replacement);

      await store.supersede(old.id, replacement.id);

      // Old should not appear in active queries.
      final active = await store.activeItemCount('durable');
      expect(active, equals(1));
    });

    test('activeItemCount with component and session filter', () async {
      await store.insert(StoredMemory(
        content: 'Task item in session one',
        component: 'task',
        category: 'goal',
        sessionId: 'ses1',
      ));
      await store.insert(StoredMemory(
        content: 'Task item in session two',
        component: 'task',
        category: 'goal',
        sessionId: 'ses2',
      ));
      await store.insert(StoredMemory(
        content: 'Durable fact stored here',
        component: 'durable',
        category: 'fact',
      ));

      expect(await store.activeItemCount('task'), equals(2));
      expect(
        await store.activeItemCount('task', sessionId: 'ses1'),
        equals(1),
      );
      expect(await store.activeItemCount('durable'), equals(1));
    });

    test('activeItemsForSession returns correct items', () async {
      await store.insert(StoredMemory(
        content: 'Active task in session',
        component: 'task',
        category: 'goal',
        sessionId: 'ses1',
      ));
      await store.insert(StoredMemory(
        content: 'Expired task in session',
        component: 'task',
        category: 'goal',
        sessionId: 'ses1',
        status: MemoryStatus.expired,
      ));

      final items = await store.activeItemsForSession('ses1', 'task');
      expect(items, hasLength(1));
      expect(items.first.content, equals('Active task in session'));
    });

    test('applyImportanceDecay decays inactive items', () async {
      final old = DateTime.now().toUtc().subtract(const Duration(days: 30));
      final oldMem = StoredMemory(
        content: 'Agent can detect code patterns automatically',
        component: 'environmental',
        category: 'capability',
        importance: 0.6,
        updatedAt: old,
      );
      await store.insert(oldMem);
      await store.insert(StoredMemory(
        content: 'User prefers functional style programming',
        component: 'environmental',
        category: 'capability',
        importance: 0.6,
      ));

      final floored = await store.applyImportanceDecay(
        component: 'environmental',
        inactivePeriod: const Duration(days: 14),
        decayRate: 0.5,
        floorThreshold: 0.1,
      );

      expect(floored, equals(0)); // 0.6 * 0.5 = 0.3 > 0.1

      // Verify the old one was decayed by checking via its ID.
      final items = await store.findSimilar(
        'detect code patterns automatically',
        'environmental',
      );
      expect(items, hasLength(1));
      expect(items.first.id, equals(oldMem.id));
      expect(items.first.importance, closeTo(0.3, 0.01));
    });

    test('applyImportanceDecay marks items below floor', () async {
      final old = DateTime.now().toUtc().subtract(const Duration(days: 30));
      await store.insert(StoredMemory(
        content: 'Very old low importance memory',
        component: 'environmental',
        category: 'pattern',
        importance: 0.15,
        updatedAt: old,
      ));

      final floored = await store.applyImportanceDecay(
        component: 'environmental',
        inactivePeriod: const Duration(days: 14),
        decayRate: 0.5,
        floorThreshold: 0.1,
      );

      expect(floored, equals(1)); // 0.15 * 0.5 = 0.075 < 0.1

      final active = await store.activeItemCount('environmental');
      expect(active, equals(0));
    });

    test('applyImportanceDecay does not affect other components', () async {
      final old = DateTime.now().toUtc().subtract(const Duration(days: 30));
      await store.insert(StoredMemory(
        content: 'Old durable memory stays here',
        component: 'durable',
        category: 'fact',
        importance: 0.6,
        updatedAt: old,
      ));

      await store.applyImportanceDecay(
        component: 'environmental',
        inactivePeriod: const Duration(days: 14),
        decayRate: 0.5,
      );

      final durableItems = await store.findSimilar(
        'Old durable memory',
        'durable',
      );
      expect(durableItems, hasLength(1));
      expect(durableItems.first.importance, equals(0.6));
    });
  });

  // ── Source episode IDs ────────────────────────────────────────────

  group('source episode IDs', () {
    test('stores and retrieves source episode IDs', () async {
      final mem = StoredMemory(
        content: 'Memory with source episodes tracking',
        component: 'task',
        category: 'goal',
        sourceEpisodeIds: ['ep1', 'ep2', 'ep3'],
      );
      await store.insert(mem);

      final results = await store.findSimilar(
        'source episodes tracking',
        'task',
      );
      expect(results, hasLength(1));
      expect(results.first.sourceEpisodeIds, equals(['ep1', 'ep2', 'ep3']));
    });

    test('updates source episode IDs', () async {
      final mem = StoredMemory(
        content: 'Memory to update sources here',
        component: 'task',
        category: 'goal',
        sourceEpisodeIds: ['ep1'],
      );
      await store.insert(mem);

      await store.update(mem.id, sourceEpisodeIds: ['ep1', 'ep2']);

      final results = await store.findSimilar(
        'update sources',
        'task',
      );
      expect(results, hasLength(1));
      expect(results.first.sourceEpisodeIds, equals(['ep1', 'ep2']));
    });
  });

  // ── Compaction operations ───────────────────────────────────────────

  group('compaction', () {
    DateTime daysAgo(int days) =>
        DateTime.now().toUtc().subtract(Duration(days: days));

    test('deleteTombstoned removes expired past cutoff', () async {
      await store.insert(StoredMemory(
        content: 'Old expired memory for deletion',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: daysAgo(10),
      ));
      await store.insert(StoredMemory(
        content: 'Recent expired memory survives',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        updatedAt: daysAgo(3),
      ));
      await store.insert(StoredMemory(
        content: 'Active memory is never touched',
        component: 'task',
        category: 'goal',
        updatedAt: daysAgo(100),
      ));

      final deleted = await store.deleteTombstoned(
        MemoryStatus.expired,
        daysAgo(7),
      );
      expect(deleted, 1);

      // FTS should still work for survivors.
      final fts = await store.searchFts('memory');
      expect(fts, hasLength(1));
      expect(fts.first.memory.content, contains('Active'));
    });

    test('deleteTombstoned removes superseded past cutoff', () async {
      await store.insert(StoredMemory(
        content: 'Old superseded memory gone',
        component: 'durable',
        category: 'fact',
        status: MemoryStatus.superseded,
        updatedAt: daysAgo(40),
      ));

      final deleted = await store.deleteTombstoned(
        MemoryStatus.superseded,
        daysAgo(30),
      );
      expect(deleted, 1);
    });

    test('deleteTombstoned removes decayed past cutoff', () async {
      await store.insert(StoredMemory(
        content: 'Old decayed memory gone now',
        component: 'environmental',
        category: 'capability',
        status: MemoryStatus.decayed,
        updatedAt: daysAgo(20),
      ));

      final deleted = await store.deleteTombstoned(
        MemoryStatus.decayed,
        daysAgo(14),
      );
      expect(deleted, 1);
    });

    test('deleteOrphanedEntities removes unreferenced', () async {
      final referenced = Entity(name: 'Dart', type: 'language');
      final orphaned = Entity(name: 'Forgotten', type: 'concept');
      await store.upsertEntity(referenced);
      await store.upsertEntity(orphaned);

      await store.insert(StoredMemory(
        content: 'Active memory references Dart language',
        component: 'durable',
        category: 'fact',
        entityIds: [referenced.id],
      ));

      final removed = await store.deleteOrphanedEntities();
      expect(removed, 1);

      final surviving = await store.findEntitiesByName('Dart');
      expect(surviving, hasLength(1));
      final gone = await store.findEntitiesByName('Forgotten');
      expect(gone, isEmpty);
    });

    test('deleteOrphanedRelationships removes dangling refs', () async {
      final e1 = Entity(name: 'Dart', type: 'language');
      final e2 = Entity(name: 'Flutter', type: 'framework');
      await store.upsertEntity(e1);
      await store.upsertEntity(e2);

      await store.upsertRelationship(Relationship(
        fromEntity: e1.id,
        toEntity: e2.id,
        relation: 'used_by',
      ));
      // Relationship referencing a non-existent entity.
      await store.upsertRelationship(Relationship(
        fromEntity: e1.id,
        toEntity: 'nonexistent_entity_id',
        relation: 'related_to',
      ));

      final removed = await store.deleteOrphanedRelationships();
      expect(removed, 1);

      final surviving = await store.findRelationshipsForEntity(e1.id);
      expect(surviving, hasLength(1));
      expect(surviving.first.toEntity, e2.id);
    });

    test('stats returns correct breakdown', () async {
      await store.insert(StoredMemory(
        content: 'Active task memory for stats',
        component: 'task',
        category: 'goal',
      ));
      await store.insert(StoredMemory(
        content: 'Active durable memory for stats',
        component: 'durable',
        category: 'fact',
      ));
      await store.insert(StoredMemory(
        content: 'Embedded active durable memory',
        component: 'durable',
        category: 'fact',
        embedding: [0.1, 0.2, 0.3],
      ));
      await store.insert(StoredMemory(
        content: 'Expired memory for stats count',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
      ));
      await store.insert(StoredMemory(
        content: 'Superseded memory for stats count',
        component: 'durable',
        category: 'fact',
        status: MemoryStatus.superseded,
      ));
      await store.insert(StoredMemory(
        content: 'Decayed memory for stats count',
        component: 'environmental',
        category: 'capability',
        status: MemoryStatus.decayed,
      ));

      await store.upsertEntity(Entity(name: 'Dart', type: 'language'));
      await store.upsertRelationship(Relationship(
        fromEntity: 'a',
        toEntity: 'b',
        relation: 'uses',
      ));

      final s = await store.stats();
      expect(s.totalMemories, 6);
      expect(s.activeMemories, 3);
      expect(s.expiredMemories, 1);
      expect(s.supersededMemories, 1);
      expect(s.decayedMemories, 1);
      expect(s.embeddedMemories, 1);
      expect(s.entities, 1);
      expect(s.relationships, 1);
      expect(s.activeByComponent['task'], 1);
      expect(s.activeByComponent['durable'], 2);
    });

    test('FTS stays consistent after tombstone deletion', () async {
      final mem = StoredMemory(
        content: 'Quantum physics breakthrough discovery',
        component: 'durable',
        category: 'fact',
        status: MemoryStatus.expired,
        updatedAt: daysAgo(10),
      );
      await store.insert(mem);

      // Should not appear in FTS (expired).
      var results = await store.searchFts('quantum physics');
      expect(results, isEmpty);

      // Delete the tombstone.
      await store.deleteTombstoned(MemoryStatus.expired, daysAgo(7));

      // Still not in FTS after physical deletion.
      results = await store.searchFts('quantum physics');
      expect(results, isEmpty);

      // Insert a new active memory with similar content.
      await store.insert(StoredMemory(
        content: 'Quantum physics experiment results',
        component: 'durable',
        category: 'fact',
      ));

      // New one should be findable.
      results = await store.searchFts('quantum physics');
      expect(results, hasLength(1));
      expect(results.first.memory.content, contains('experiment'));
    });
  });
}
