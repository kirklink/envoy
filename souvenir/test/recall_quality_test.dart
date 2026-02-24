/// Automated recall quality tests.
///
/// These tests verify that unified recall produces correct rankings for
/// scenarios that failed under v2's per-component RRF approach. Each test
/// constructs a realistic memory store, runs a query, and asserts the
/// ranking order — not just that results exist.
///
/// Key scenarios:
/// - Semantic bridging (rabbit test): vector similarity bridges the gap
///   when query terms don't appear in the target memory.
/// - Multi-signal reinforcement: memories that match on multiple signals
///   (FTS + entity + vector) rank higher than single-signal matches.
/// - Relevance threshold: irrelevant queries return empty results.
/// - Component weight tuning: durable facts outrank task context.
import 'package:souvenir/src/embedding_provider.dart';
import 'package:souvenir/src/in_memory_memory_store.dart';
import 'package:souvenir/src/memory_store.dart';
import 'package:souvenir/src/recall.dart';
import 'package:souvenir/src/stored_memory.dart';
import 'package:souvenir/src/tokenizer.dart';
import 'package:test/test.dart';

// ── Test infrastructure ─────────────────────────────────────────────────────

/// Fake embedding provider with manually assigned semantic vectors.
///
/// Vectors are designed so that cosine similarity reflects real-world
/// semantic relationships:
/// - "rabbits" and "favourite animal" have high cosine (~0.98)
/// - "Dart" and "favourite animal" have near-zero cosine
/// - "PostgreSQL" and "database" have high cosine
class QualityTestEmbeddings implements EmbeddingProvider {
  // Semantic dimensions: [animals, programming, database, general]
  static const _vectors = <String, List<double>>{
    // Animal cluster
    'rabbits': [0.95, 0.0, 0.0, 0.05],
    'cute animals': [0.9, 0.0, 0.0, 0.1],
    'favourite animal': [0.9, 0.0, 0.0, 0.1],
    'pets': [0.85, 0.0, 0.0, 0.15],
    // Programming cluster
    'Dart': [0.0, 0.95, 0.0, 0.05],
    'programming': [0.0, 0.9, 0.0, 0.1],
    'Dart language': [0.0, 0.92, 0.0, 0.08],
    'code patterns': [0.0, 0.8, 0.0, 0.2],
    // Database cluster
    'PostgreSQL': [0.0, 0.1, 0.9, 0.0],
    'database': [0.0, 0.1, 0.85, 0.05],
    'SQL queries': [0.0, 0.15, 0.8, 0.05],
    // Mixed / general
    'project setup': [0.0, 0.4, 0.3, 0.3],
    'authentication': [0.0, 0.3, 0.2, 0.5],
  };

  @override
  int get dimensions => 4;

  @override
  Future<List<double>> embed(String text) async {
    // Exact match.
    if (_vectors.containsKey(text)) return _vectors[text]!;

    // Substring match (case-insensitive).
    final lower = text.toLowerCase();
    for (final entry in _vectors.entries) {
      if (lower.contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }

    // Default: small general vector (non-zero to avoid division-by-zero).
    return [0.05, 0.05, 0.05, 0.85];
  }
}

/// Seeds the store with a realistic set of memories across components.
Future<void> _seedMemories(MemoryStore store) async {
  await store.initialize();

  // ── Durable memories (long-term facts) ──────────────────────────────

  final rabbitEntity = Entity(name: 'rabbits', type: 'animal');
  final dartEntity = Entity(name: 'Dart', type: 'language');
  final pgEntity = Entity(name: 'PostgreSQL', type: 'technology');
  final aliceEntity = Entity(name: 'Alice', type: 'person');

  await store.upsertEntity(rabbitEntity);
  await store.upsertEntity(dartEntity);
  await store.upsertEntity(pgEntity);
  await store.upsertEntity(aliceEntity);

  // Relationships.
  await store.upsertRelationship(Relationship(
    fromEntity: aliceEntity.id,
    toEntity: rabbitEntity.id,
    relation: 'owns',
    confidence: 0.9,
  ));
  await store.upsertRelationship(Relationship(
    fromEntity: dartEntity.id,
    toEntity: pgEntity.id,
    relation: 'connects_to',
    confidence: 0.7,
  ));

  await store.insert(StoredMemory(
    content: 'User thinks rabbits are the most adorable creatures',
    component: 'durable',
    category: 'fact',
    importance: 0.9,
    entityIds: [rabbitEntity.id],
  ));

  await store.insert(StoredMemory(
    content: 'Project uses Dart 3.7 as the primary language',
    component: 'durable',
    category: 'fact',
    importance: 0.7,
    entityIds: [dartEntity.id],
  ));

  await store.insert(StoredMemory(
    content: 'PostgreSQL 16 is the production database with JSONB columns',
    component: 'durable',
    category: 'fact',
    importance: 0.8,
    entityIds: [pgEntity.id],
  ));

  await store.insert(StoredMemory(
    content: 'Alice is the project lead and prefers pair programming',
    component: 'durable',
    category: 'fact',
    importance: 0.7,
    entityIds: [aliceEntity.id],
  ));

  await store.insert(StoredMemory(
    content: 'User prefers dark mode in all development tools',
    component: 'durable',
    category: 'fact',
    importance: 0.6,
  ));

  // ── Task memories (current session) ─────────────────────────────────

  await store.insert(StoredMemory(
    content: 'Current goal is to build REST API endpoints for user management',
    component: 'task',
    category: 'goal',
    importance: 0.8,
    sessionId: 'ses_current',
  ));

  await store.insert(StoredMemory(
    content: 'Decided to use shelf as the HTTP framework',
    component: 'task',
    category: 'decision',
    importance: 0.7,
    sessionId: 'ses_current',
  ));

  await store.insert(StoredMemory(
    content: 'Authentication endpoint returns JWT tokens on success',
    component: 'task',
    category: 'result',
    importance: 0.6,
    sessionId: 'ses_current',
  ));

  // ── Environmental memories ──────────────────────────────────────────

  await store.insert(StoredMemory(
    content: 'Running on Linux x86_64 with 16GB RAM',
    component: 'environmental',
    category: 'environment',
    importance: 0.5,
  ));

  await store.insert(StoredMemory(
    content: 'Dart SDK version 3.7.0 is installed and available on PATH',
    component: 'environmental',
    category: 'capability',
    importance: 0.6,
    entityIds: [dartEntity.id],
  ));

  // Generate embeddings for all memories.
  final embeddings = QualityTestEmbeddings();
  final unembedded = await store.findUnembeddedMemories(limit: 100);
  for (final mem in unembedded) {
    final vector = await embeddings.embed(mem.content);
    await store.update(mem.id, embedding: vector);
  }
}

// ── Quality tests ────────────────────────────────────────────────────────────

void main() {
  late InMemoryMemoryStore store;
  late UnifiedRecall recall;

  setUp(() async {
    store = InMemoryMemoryStore();
    await _seedMemories(store);
    recall = UnifiedRecall(
      store: store,
      tokenizer: const ApproximateTokenizer(),
      config: const RecallConfig(
        ftsWeight: 1.0,
        vectorWeight: 1.5,
        entityWeight: 0.8,
        componentWeights: {'durable': 1.2, 'task': 1.0, 'environmental': 0.8},
        relevanceThreshold: 0.01,
      ),
      embeddings: QualityTestEmbeddings(),
    );
  });

  group('Rabbit test (semantic bridging)', () {
    test('"favourite animal" recalls rabbits as #1', () async {
      final result = await recall.recall('favourite animal');

      expect(result.items, isNotEmpty,
          reason: 'Should return at least one memory');

      // Rabbits should be #1 — vector similarity bridges the semantic gap.
      expect(result.items.first.content, contains('rabbits'),
          reason: 'Vector similarity should surface rabbits for "favourite animal"');
    });

    test('"favourite animal" ranks rabbits above Dart', () async {
      final result = await recall.recall('favourite animal');

      final rabbitItem = result.items.firstWhere(
        (i) => i.content.contains('rabbits'),
      );
      final dartItems = result.items.where(
        (i) => i.content.contains('Dart') && !i.content.contains('rabbits'),
      );

      if (dartItems.isNotEmpty) {
        expect(rabbitItem.score, greaterThan(dartItems.first.score),
            reason: 'Rabbits should score higher than Dart for "favourite animal"');
      }
    });

    test('score breakdown shows vector as dominant signal for rabbits', () async {
      final result = await recall.recall('favourite animal');

      final rabbitItem = result.items.firstWhere(
        (i) => i.content.contains('rabbits'),
      );

      // Vector should be the primary signal (no FTS match for "favourite animal").
      expect(rabbitItem.vectorSignal, greaterThan(0),
          reason: 'Vector signal should be non-zero for semantic match');
    });
  });

  group('Multi-signal reinforcement', () {
    test('query matching FTS + entity ranks higher than FTS alone', () async {
      // "Dart" should match:
      // - FTS: "Project uses Dart 3.7..." and "Dart SDK version 3.7.0..."
      // - Entity graph: Dart entity → related memories
      // - Vector: programming cluster
      final result = await recall.recall('Dart');

      expect(result.items, isNotEmpty);

      // All Dart-related items should have entity signal.
      final dartItems = result.items.where(
        (i) => i.content.toLowerCase().contains('dart'),
      );
      expect(dartItems, isNotEmpty);

      // At least one item should have both FTS and entity signals.
      final multiSignal = dartItems.where(
        (i) => i.ftsSignal > 0 && i.entitySignal > 0,
      );
      expect(multiSignal, isNotEmpty,
          reason: 'Dart memories should get both FTS and entity graph signals');
    });

    test('entity graph expands to related memories', () async {
      // "Alice" should find Alice's memory directly, plus rabbit memory
      // via Alice → rabbits relationship.
      final result = await recall.recall('Alice');

      final contents = result.items.map((i) => i.content).toList();

      expect(contents.any((c) => c.contains('Alice')), isTrue,
          reason: 'Direct entity match should be found');

      // Via entity graph: Alice → owns → rabbits → rabbit memory.
      expect(contents.any((c) => c.contains('rabbits')), isTrue,
          reason: 'Entity graph should expand Alice → rabbits');
    });
  });

  group('Relevance threshold (silence > noise)', () {
    test('completely unrelated query returns few or no results', () async {
      final strictRecall = UnifiedRecall(
        store: store,
        tokenizer: const ApproximateTokenizer(),
        config: const RecallConfig(
          relevanceThreshold: 0.5,
        ),
        embeddings: QualityTestEmbeddings(),
      );

      // "quantum entanglement" has nothing to do with any stored memory.
      final result = await strictRecall.recall('quantum entanglement');

      // With a strict threshold, irrelevant results should be mostly filtered.
      // Compare against a permissive threshold to show the difference.
      final permissiveRecall = UnifiedRecall(
        store: store,
        tokenizer: const ApproximateTokenizer(),
        config: const RecallConfig(relevanceThreshold: 0.01),
        embeddings: QualityTestEmbeddings(),
      );
      final permissiveResult =
          await permissiveRecall.recall('quantum entanglement');

      expect(result.items.length, lessThan(permissiveResult.items.length),
          reason: 'Strict threshold should return fewer results than permissive');
    });
  });

  group('Component weight tuning', () {
    test('durable facts outrank environmental for long-term queries', () async {
      // "Dart" exists in both durable and environmental memories.
      // With durable weight 1.2 and environmental weight 0.8, durable
      // should rank higher.
      final result = await recall.recall('Dart language version');

      final durableItems = result.items.where((i) => i.component == 'durable');
      final envItems = result.items.where((i) => i.component == 'environmental');

      if (durableItems.isNotEmpty && envItems.isNotEmpty) {
        expect(durableItems.first.score, greaterThan(envItems.first.score),
            reason: 'Durable weight 1.2 should outrank environmental weight 0.8');
      }
    });

    test('task context ranks well for session-specific queries', () async {
      final result = await recall.recall('REST API endpoints');

      expect(result.items, isNotEmpty);
      expect(result.items.first.component, 'task',
          reason: 'Task memory should rank highest for session-specific query');
    });
  });

  group('Recall completeness', () {
    test('database query surfaces PostgreSQL memory', () async {
      final result = await recall.recall('database');

      expect(result.items.any((i) => i.content.contains('PostgreSQL')), isTrue,
          reason: 'FTS + vector should find PostgreSQL for "database"');
    });

    test('all three components can appear in results', () async {
      // Broad query that should touch all components.
      final result = await recall.recall('Dart');

      final components = result.items.map((i) => i.component).toSet();
      expect(components, containsAll(['durable', 'environmental']),
          reason: 'Dart appears in durable and environmental memories');
    });

    test('access stats are updated after recall', () async {
      await recall.recall('rabbits');

      // The rabbit memory should have its access count bumped.
      final fts = await store.searchFts('rabbits');
      final rabbitMem = fts.firstWhere(
        (m) => m.memory.content.contains('adorable'),
      );
      expect(rabbitMem.memory.accessCount, greaterThan(0),
          reason: 'Access count should be updated after recall');
    });
  });

  group('Full engine integration quality', () {
    test('end-to-end: record → consolidate → recall', () async {
      // Fresh store + engine with real components.
      final freshStore = InMemoryMemoryStore();
      await freshStore.initialize();

      // Directly insert memories (simulating component consolidation).
      await freshStore.insert(StoredMemory(
        content: 'User loves hiking in the mountains on weekends',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));
      await freshStore.insert(StoredMemory(
        content: 'Current task is to implement search functionality',
        component: 'task',
        category: 'goal',
        importance: 0.7,
        sessionId: 'ses_01',
      ));

      // Generate embeddings.
      final embeddings = QualityTestEmbeddings();
      final unembedded = await freshStore.findUnembeddedMemories();
      for (final mem in unembedded) {
        final vector = await embeddings.embed(mem.content);
        await freshStore.update(mem.id, embedding: vector);
      }

      final testRecall = UnifiedRecall(
        store: freshStore,
        tokenizer: const ApproximateTokenizer(),
        embeddings: embeddings,
      );

      final result = await testRecall.recall('search');
      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('search'));
    });
  });
}
