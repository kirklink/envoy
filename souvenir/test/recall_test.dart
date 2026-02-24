import 'package:test/test.dart';

import 'package:souvenir/src/stored_memory.dart';
import 'package:souvenir/src/in_memory_memory_store.dart';
import 'package:souvenir/src/recall.dart';
import 'package:souvenir/src/tokenizer.dart';
import 'package:souvenir/src/embedding_provider.dart';

// ── Test helpers ─────────────────────────────────────────────────────────────

/// Fake embedding provider with deterministic vectors.
///
/// Maps predefined text → vector. Falls back to a zero vector.
class FakeEmbeddingProvider implements EmbeddingProvider {
  final Map<String, List<double>> _vectors;

  @override
  final int dimensions;

  FakeEmbeddingProvider(this._vectors, {this.dimensions = 8});

  @override
  Future<List<double>> embed(String text) async {
    // Check for exact match first.
    if (_vectors.containsKey(text)) return _vectors[text]!;

    // Check for substring match (query matching).
    for (final entry in _vectors.entries) {
      if (text.toLowerCase().contains(entry.key.toLowerCase()) ||
          entry.key.toLowerCase().contains(text.toLowerCase())) {
        return entry.value;
      }
    }

    return List.filled(dimensions, 0.0);
  }
}

/// Creates a unit vector pointing in a specific direction.
/// Angle 0 = [1,0,...], angle pi/2 = [0,1,0,...], etc.
List<double> _vectorAt(double angle, {int dims = 8}) {
  final v = List.filled(dims, 0.0);
  v[0] = _cos(angle);
  v[1] = _sin(angle);
  return v;
}

double _cos(double x) {
  // Taylor series approximation.
  var result = 1.0;
  var term = 1.0;
  for (var i = 1; i <= 20; i++) {
    term *= -x * x / ((2 * i - 1) * (2 * i));
    result += term;
  }
  return result;
}

double _sin(double x) {
  var result = x;
  var term = x;
  for (var i = 1; i <= 20; i++) {
    term *= -x * x / ((2 * i) * (2 * i + 1));
    result += term;
  }
  return result;
}

void main() {
  late InMemoryMemoryStore store;
  late ApproximateTokenizer tokenizer;

  setUp(() async {
    store = InMemoryMemoryStore();
    await store.initialize();
    tokenizer = ApproximateTokenizer();
  });

  // ── Basic recall ──────────────────────────────────────────────────

  group('basic recall', () {
    test('returns empty for empty store', () async {
      final recall = UnifiedRecall(store: store, tokenizer: tokenizer);
      final result = await recall.recall('anything');
      expect(result.items, isEmpty);
    });

    test('finds memories via FTS keyword match', () async {
      await store.insert(StoredMemory(
        content: 'User prefers Dart programming language',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));
      await store.insert(StoredMemory(
        content: 'User finds rabbits very cute animals',
        component: 'durable',
        category: 'fact',
        importance: 0.4,
      ));

      final recall = UnifiedRecall(store: store, tokenizer: tokenizer);
      final result = await recall.recall('Dart programming');

      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('Dart'));
      expect(result.items.first.ftsSignal, greaterThan(0));
    });

    test('searches across all components', () async {
      await store.insert(StoredMemory(
        content: 'User wants to write Dart functions',
        component: 'task',
        category: 'goal',
        importance: 0.6,
      ));
      await store.insert(StoredMemory(
        content: 'User prefers Dart over Python',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));
      await store.insert(StoredMemory(
        content: 'Agent can provide Dart code examples',
        component: 'environmental',
        category: 'capability',
        importance: 0.5,
      ));

      final recall = UnifiedRecall(store: store, tokenizer: tokenizer);
      final result = await recall.recall('Dart');

      // All three should appear.
      final components = result.items.map((i) => i.component).toSet();
      expect(components, containsAll(['task', 'durable', 'environmental']));
    });

    test('excludes expired memories', () async {
      await store.insert(StoredMemory(
        content: 'Expired task about Dart coding',
        component: 'task',
        category: 'goal',
        status: MemoryStatus.expired,
        importance: 0.9,
      ));

      final recall = UnifiedRecall(store: store, tokenizer: tokenizer);
      final result = await recall.recall('Dart coding');
      expect(result.items, isEmpty);
    });
  });

  // ── Vector recall ─────────────────────────────────────────────────

  group('vector recall', () {
    test('finds semantically similar memories via embeddings', () async {
      // "favourite animal" and "rabbits cute" are semantically similar
      // but share no keywords. Only vector search bridges this gap.
      final queryVec = _vectorAt(0.0); // query direction
      final rabbitVec = _vectorAt(0.1); // close to query
      final dartVec = _vectorAt(1.5); // far from query (pi/2 ≈ orthogonal)

      final embeddings = FakeEmbeddingProvider({
        'favourite animal': queryVec,
        'User finds rabbits cute': rabbitVec,
        'User prefers Dart programming': dartVec,
      });

      await store.insert(StoredMemory(
        content: 'User finds rabbits cute',
        component: 'durable',
        category: 'fact',
        importance: 0.4,
        embedding: rabbitVec,
      ));
      await store.insert(StoredMemory(
        content: 'User prefers Dart programming',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
        embedding: dartVec,
      ));

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        embeddings: embeddings,
        config: const RecallConfig(
          ftsWeight: 1.0,
          vectorWeight: 1.5,
          relevanceThreshold: 0.01,
        ),
      );

      final result = await recall.recall('favourite animal');

      // Rabbits should rank higher due to vector similarity,
      // even though Dart has higher importance.
      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('rabbits'));
      expect(result.items.first.vectorSignal, greaterThan(0.9));
    });

    test('vector-only match works when FTS returns nothing', () async {
      final queryVec = _vectorAt(0.0);
      final matchVec = _vectorAt(0.05); // very close

      final embeddings = FakeEmbeddingProvider({
        'xyzzy': queryVec, // query
        'User finds rabbits cute': matchVec,
      });

      await store.insert(StoredMemory(
        content: 'User finds rabbits cute',
        component: 'durable',
        category: 'fact',
        importance: 0.5,
        embedding: matchVec,
      ));

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        embeddings: embeddings,
        config: const RecallConfig(
          vectorWeight: 1.5,
          relevanceThreshold: 0.01,
        ),
      );

      // "xyzzy" has no keyword overlap with any memory.
      final result = await recall.recall('xyzzy');
      expect(result.items, hasLength(1));
      expect(result.items.first.content, contains('rabbits'));
      expect(result.items.first.ftsSignal, equals(0));
      expect(result.items.first.vectorSignal, greaterThan(0.9));
    });
  });

  // ── Entity graph recall ───────────────────────────────────────────

  group('entity graph recall', () {
    test('entity match boosts related memories', () async {
      final entity = Entity(name: 'Dart', type: 'language');
      await store.upsertEntity(entity);

      await store.insert(StoredMemory(
        content: 'User prefers strongly typed languages for safety',
        component: 'durable',
        category: 'fact',
        importance: 0.7,
        entityIds: [entity.id],
      ));
      await store.insert(StoredMemory(
        content: 'User finds rabbits cute and adorable',
        component: 'durable',
        category: 'fact',
        importance: 0.4,
      ));

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: const RecallConfig(
          entityWeight: 0.8,
          relevanceThreshold: 0.01,
        ),
      );

      final result = await recall.recall('Dart programming');

      expect(result.items, isNotEmpty);
      // The entity-linked memory should appear and have entitySignal > 0.
      final entityLinked = result.items.firstWhere(
        (i) => i.content.contains('typed languages'),
      );
      expect(entityLinked.entitySignal, greaterThan(0));
    });

    test('1-hop entity expansion reaches related memories', () async {
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

      await store.insert(StoredMemory(
        content: 'User builds mobile apps with cross platform tools',
        component: 'durable',
        category: 'fact',
        importance: 0.7,
        entityIds: [flutter.id],
      ));

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: const RecallConfig(
          entityWeight: 0.8,
          relevanceThreshold: 0.01,
        ),
      );

      // Query mentions "Dart" → finds Dart entity → 1-hop to Flutter →
      // finds Flutter-linked memory.
      final result = await recall.recall('Dart');

      expect(result.items, isNotEmpty);
      final flutterLinked = result.items.firstWhere(
        (i) => i.content.contains('mobile apps'),
      );
      expect(flutterLinked.entitySignal, greaterThan(0));
      // Confidence is 0.9 (from relationship), not 1.0 (1-hop).
      expect(flutterLinked.entitySignal, closeTo(0.9, 0.01));
    });
  });

  // ── Score fusion ──────────────────────────────────────────────────

  group('score fusion', () {
    test('component weights affect ranking', () async {
      await store.insert(StoredMemory(
        content: 'Task: user wants to write Dart functions',
        component: 'task',
        category: 'goal',
        importance: 0.6,
      ));
      await store.insert(StoredMemory(
        content: 'Durable: user prefers Dart programming style',
        component: 'durable',
        category: 'fact',
        importance: 0.6,
      ));

      // Weight durable higher.
      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: const RecallConfig(
          componentWeights: {'durable': 2.0, 'task': 0.5},
          relevanceThreshold: 0.01,
        ),
      );

      final result = await recall.recall('Dart');
      expect(result.items.length, greaterThanOrEqualTo(2));
      // Durable should rank first due to 4x weight advantage (2.0 vs 0.5).
      expect(result.items.first.component, equals('durable'));
    });

    test('importance multiplier affects ranking', () async {
      await store.insert(StoredMemory(
        content: 'Low importance memory about Dart code',
        component: 'durable',
        category: 'fact',
        importance: 0.1,
      ));
      await store.insert(StoredMemory(
        content: 'High importance memory about Dart programming',
        component: 'durable',
        category: 'fact',
        importance: 0.9,
      ));

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: const RecallConfig(relevanceThreshold: 0.001),
      );

      final result = await recall.recall('Dart');
      expect(result.items.length, greaterThanOrEqualTo(2));
      expect(result.items.first.content, contains('High importance'));
    });

    test('relevance threshold filters noise', () async {
      await store.insert(StoredMemory(
        content: 'Barely relevant memory about something or other',
        component: 'environmental',
        category: 'pattern',
        importance: 0.01, // Very low importance → score below threshold.
      ));

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: const RecallConfig(relevanceThreshold: 0.05),
      );

      final result = await recall.recall('relevant memory');
      expect(result.items, isEmpty);
    });

    test('empty recall when nothing matches', () async {
      await store.insert(StoredMemory(
        content: 'User prefers Dart programming',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));

      final recall = UnifiedRecall(store: store, tokenizer: tokenizer);
      final result = await recall.recall('quantum physics');
      expect(result.items, isEmpty);
    });
  });

  // ── Budget trimming ───────────────────────────────────────────────

  group('budget trimming', () {
    test('respects token budget', () async {
      // Insert many memories so total would exceed budget.
      for (var i = 0; i < 20; i++) {
        await store.insert(StoredMemory(
          content: 'Memory number $i about Dart programming techniques',
          component: 'durable',
          category: 'fact',
          importance: 0.8,
        ));
      }

      final recall = UnifiedRecall(store: store, tokenizer: tokenizer);
      // Very small budget.
      final result = await recall.recall('Dart programming', budgetTokens: 50);

      // Should have fewer items than available.
      expect(result.items.length, lessThan(20));
      expect(result.totalTokens, lessThanOrEqualTo(50 + 20)); // +tolerance for first item
    });

    test('always includes at least one item', () async {
      await store.insert(StoredMemory(
        content: 'A very long memory about Dart programming that exceeds any small budget',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));

      final recall = UnifiedRecall(store: store, tokenizer: tokenizer);
      final result = await recall.recall('Dart programming', budgetTokens: 1);

      expect(result.items, hasLength(1));
    });
  });

  // ── Score breakdown ───────────────────────────────────────────────

  group('score breakdown', () {
    test('ScoredRecall includes signal breakdown', () async {
      await store.insert(StoredMemory(
        content: 'User prefers Dart programming language',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: const RecallConfig(relevanceThreshold: 0.01),
      );
      final result = await recall.recall('Dart programming');

      expect(result.items, hasLength(1));
      final item = result.items.first;
      expect(item.ftsSignal, greaterThan(0));
      expect(item.vectorSignal, equals(0)); // No embeddings.
      expect(item.score, greaterThan(0));
      expect(item.tokens, greaterThan(0));
      expect(item.component, equals('durable'));
      expect(item.category, equals('fact'));
    });
  });

  // ── Access stats ──────────────────────────────────────────────────

  group('access stats', () {
    test('recall updates access stats for returned items', () async {
      final mem = StoredMemory(
        content: 'User prefers Dart programming language',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      );
      await store.insert(mem);

      final recall = UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: const RecallConfig(relevanceThreshold: 0.01),
      );
      await recall.recall('Dart programming');

      // Check that access count was bumped.
      final items = await store.findSimilar('Dart programming', 'durable');
      expect(items.first.accessCount, equals(1));
      expect(items.first.lastAccessed, isNotNull);
    });
  });

  // ── The rabbit test ───────────────────────────────────────────────

  group('semantic bridging (the rabbit test)', () {
    test(
      'favourite animal query finds rabbits via vector when FTS fails',
      () async {
        // This is THE test: "favourite animal" → "rabbits cute" with no
        // keyword overlap, bridged only by vector similarity.

        final queryVec = _vectorAt(0.0); // "favourite animal" direction
        final rabbitVec = _vectorAt(0.15); // close to query (cosine ~0.99)
        final dartVec = _vectorAt(1.5); // far (cosine ~0.07)

        final embeddings = FakeEmbeddingProvider({
          'favourite animal': queryVec,
          'User finds rabbits cute and enjoys learning about them': rabbitVec,
          'User is interested in Dart programming': dartVec,
        });

        await store.insert(StoredMemory(
          content:
              'User finds rabbits cute and enjoys learning about them',
          component: 'durable',
          category: 'fact',
          importance: 0.4,
          embedding: rabbitVec,
        ));
        await store.insert(StoredMemory(
          content: 'User is interested in Dart programming',
          component: 'durable',
          category: 'fact',
          importance: 0.8,
          embedding: dartVec,
        ));
        await store.insert(StoredMemory(
          content: 'User wants to write Dart functions using lists',
          component: 'task',
          category: 'goal',
          importance: 0.6,
        ));
        await store.insert(StoredMemory(
          content: 'Agent can provide code examples in multiple styles',
          component: 'environmental',
          category: 'capability',
          importance: 0.5,
        ));

        final recall = UnifiedRecall(
          store: store,
          tokenizer: tokenizer,
          embeddings: embeddings,
          config: const RecallConfig(
            ftsWeight: 1.0,
            vectorWeight: 1.5,
            entityWeight: 0.8,
            relevanceThreshold: 0.01,
          ),
        );

        final result = await recall.recall('favourite animal');

        // Rabbits MUST rank first.
        expect(result.items, isNotEmpty,
            reason: 'Should recall at least the rabbit memory');
        expect(result.items.first.content, contains('rabbits'),
            reason: 'Rabbits must rank #1 for "favourite animal" query');

        // Rabbits should score significantly higher than Dart.
        if (result.items.length >= 2) {
          final rabbitScore = result.items
              .firstWhere((i) => i.content.contains('rabbits'))
              .score;
          final dartResults = result.items
              .where((i) => i.content.contains('Dart programming'));
          if (dartResults.isNotEmpty) {
            expect(rabbitScore, greaterThan(dartResults.first.score * 2),
                reason: 'Rabbits should score >2x higher than Dart');
          }
        }
      },
    );
  });
}
