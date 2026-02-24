import 'package:souvenir/src/embedding_provider.dart';
import 'package:souvenir/src/engine.dart';
import 'package:souvenir/src/episode_store.dart';
import 'package:souvenir/src/in_memory_memory_store.dart';
import 'package:souvenir/src/llm_callback.dart';
import 'package:souvenir/src/memory_component.dart';
import 'package:souvenir/src/memory_store.dart';
import 'package:souvenir/src/models/episode.dart';
import 'package:souvenir/src/recall.dart';
import 'package:souvenir/src/stored_memory.dart';
import 'package:souvenir/src/tokenizer.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

Episode _episode(String content, {String sessionId = 'ses_01'}) {
  return Episode(
    sessionId: sessionId,
    type: EpisodeType.observation,
    content: content,
  );
}

/// Minimal component that writes a fixed set of items when consolidating.
class TestComponent implements MemoryComponent {
  @override
  final String name;

  final MemoryStore _store;
  bool initialized = false;
  bool closed = false;
  int consolidateCount = 0;

  /// JSON response to return from LLM. Key varies by component type.
  final Map<String, dynamic> Function(List<Episode>)? llmResponse;

  /// Simple: just write fixed items to the store.
  final List<StoredMemory> itemsToCreate;

  TestComponent({
    required this.name,
    required MemoryStore store,
    this.llmResponse,
    this.itemsToCreate = const [],
  }) : _store = store;

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
  ) async {
    consolidateCount++;
    var created = 0;
    for (final item in itemsToCreate) {
      await _store.insert(item);
      created++;
    }
    return ConsolidationReport(
      componentName: name,
      itemsCreated: created,
      episodesConsumed: episodes.length,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// Embedding provider that returns deterministic vectors for testing.
class FakeEmbeddingProvider implements EmbeddingProvider {
  final Map<String, List<double>> _vectors;

  @override
  final int dimensions;

  FakeEmbeddingProvider(this._vectors, {this.dimensions = 4});

  @override
  Future<List<double>> embed(String text) async {
    // Check for exact match first.
    if (_vectors.containsKey(text)) return _vectors[text]!;

    // Then check for substring match.
    for (final entry in _vectors.entries) {
      if (text.toLowerCase().contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }

    // Default: zero vector.
    return List.filled(dimensions, 0.0);
  }
}

Future<String> _noopLlm(String system, String user) async => '';

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // Engine lifecycle
  // ══════════════════════════════════════════════════════════════════════════

  group('Engine lifecycle', () {
    test('initialize initializes store and components', () async {
      final store = InMemoryMemoryStore();
      final comp = TestComponent(name: 'test', store: store);

      final engine = Souvenir(
        components: [comp],
        store: store,
      );

      expect(comp.initialized, isFalse);
      await engine.initialize();
      expect(comp.initialized, isTrue);
    });

    test('record throws before initialization', () async {
      final store = InMemoryMemoryStore();
      final engine = Souvenir(components: [], store: store);

      expect(
        () => engine.record(_episode('test')),
        throwsStateError,
      );
    });

    test('close flushes buffer and closes components', () async {
      final store = InMemoryMemoryStore();
      final comp = TestComponent(name: 'test', store: store);
      final episodeStore = InMemoryEpisodeStore();

      final engine = Souvenir(
        components: [comp],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();
      await engine.record(_episode('buffered'));

      expect(engine.bufferSize, 1);
      await engine.close();

      expect(comp.closed, isTrue);
      expect(episodeStore.length, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Episode recording
  // ══════════════════════════════════════════════════════════════════════════

  group('Episode recording', () {
    test('record buffers episodes', () async {
      final store = InMemoryMemoryStore();
      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      await engine.record(_episode('one'));
      await engine.record(_episode('two'));

      expect(engine.bufferSize, 2);
    });

    test('auto-flush at threshold', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();
      final engine = Souvenir(
        components: [],
        store: store,
        episodeStore: episodeStore,
        flushThreshold: 3,
      );
      await engine.initialize();

      await engine.record(_episode('one'));
      await engine.record(_episode('two'));
      expect(engine.bufferSize, 2);
      expect(episodeStore.length, 0);

      await engine.record(_episode('three'));
      expect(engine.bufferSize, 0);
      expect(episodeStore.length, 3);
    });

    test('manual flush empties buffer', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();
      final engine = Souvenir(
        components: [],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();

      await engine.record(_episode('one'));
      await engine.flush();

      expect(engine.bufferSize, 0);
      expect(episodeStore.length, 1);
    });

    test('flush is no-op when buffer is empty', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();
      final engine = Souvenir(
        components: [],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();

      await engine.flush();
      expect(episodeStore.length, 0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Consolidation
  // ══════════════════════════════════════════════════════════════════════════

  group('Consolidation', () {
    test('consolidation passes episodes to all components', () async {
      final store = InMemoryMemoryStore();
      final comp1 = TestComponent(name: 'a', store: store);
      final comp2 = TestComponent(name: 'b', store: store);

      final engine = Souvenir(
        components: [comp1, comp2],
        store: store,
      );
      await engine.initialize();

      await engine.record(_episode('test content'));
      final reports = await engine.consolidate(_noopLlm);

      expect(reports, hasLength(2));
      expect(comp1.consolidateCount, 1);
      expect(comp2.consolidateCount, 1);
    });

    test('consolidation returns empty when no episodes', () async {
      final store = InMemoryMemoryStore();
      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final reports = await engine.consolidate(_noopLlm);
      expect(reports, isEmpty);
    });

    test('episodes marked consolidated after processing', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();
      final engine = Souvenir(
        components: [TestComponent(name: 'test', store: store)],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      expect(episodeStore.unconsolidatedCount, 0);
    });

    test('flushes buffer before consolidation', () async {
      final store = InMemoryMemoryStore();
      final episodeStore = InMemoryEpisodeStore();
      final comp = TestComponent(name: 'test', store: store);

      final engine = Souvenir(
        components: [comp],
        store: store,
        episodeStore: episodeStore,
      );
      await engine.initialize();

      await engine.record(_episode('buffered'));
      expect(engine.bufferSize, 1);

      await engine.consolidate(_noopLlm);
      expect(engine.bufferSize, 0);
      expect(comp.consolidateCount, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Unified recall (integration)
  // ══════════════════════════════════════════════════════════════════════════

  group('Unified recall via engine', () {
    test('recalls memories created by components', () async {
      final store = InMemoryMemoryStore();
      final comp = TestComponent(
        name: 'task',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'User wants to build a REST API',
            component: 'task',
            category: 'goal',
            importance: 0.8,
          ),
          StoredMemory(
            content: 'Using shelf as the HTTP framework',
            component: 'task',
            category: 'decision',
            importance: 0.7,
          ),
        ],
      );

      final engine = Souvenir(
        components: [comp],
        store: store,
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      final result = await engine.recall('REST API');
      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('REST API'));
    });

    test('recalls across multiple components', () async {
      final store = InMemoryMemoryStore();

      final taskComp = TestComponent(
        name: 'task',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'Building authentication module',
            component: 'task',
            category: 'goal',
            importance: 0.8,
          ),
        ],
      );

      final durableComp = TestComponent(
        name: 'durable',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'User prefers JWT for authentication tokens',
            component: 'durable',
            category: 'fact',
            importance: 0.9,
          ),
        ],
      );

      final engine = Souvenir(
        components: [taskComp, durableComp],
        store: store,
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      final result = await engine.recall('authentication');
      expect(result.items, hasLength(2));

      final components = result.items.map((i) => i.component).toSet();
      expect(components, containsAll(['task', 'durable']));
    });

    test('empty recall when no memories exist', () async {
      final store = InMemoryMemoryStore();
      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      final result = await engine.recall('anything');
      expect(result.items, isEmpty);
    });

    test('component weights affect ranking', () async {
      final store = InMemoryMemoryStore();

      final taskComp = TestComponent(
        name: 'task',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'Database migration task for PostgreSQL setup',
            component: 'task',
            category: 'goal',
            importance: 0.8,
          ),
        ],
      );

      final durableComp = TestComponent(
        name: 'durable',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'PostgreSQL is the preferred database for this project',
            component: 'durable',
            category: 'fact',
            importance: 0.8,
          ),
        ],
      );

      final engine = Souvenir(
        components: [taskComp, durableComp],
        store: store,
        recallConfig: RecallConfig(
          componentWeights: {'durable': 2.0, 'task': 0.5},
        ),
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      final result = await engine.recall('PostgreSQL');
      expect(result.items, hasLength(2));
      // Durable should rank higher due to 2.0 weight vs 0.5.
      expect(result.items.first.component, 'durable');
    });

    test('budget tokens limits recall', () async {
      final store = InMemoryMemoryStore();
      final items = <StoredMemory>[];
      for (var i = 0; i < 20; i++) {
        items.add(StoredMemory(
          content: 'Memory item number $i about widgets and components',
          component: 'task',
          category: 'context',
          importance: 0.5,
        ));
      }

      final engine = Souvenir(
        components: [
          TestComponent(name: 'task', store: store, itemsToCreate: items),
        ],
        store: store,
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      // Very small budget — should only return a few items.
      final result = await engine.recall('widgets', budgetTokens: 30);
      expect(result.items.length, lessThan(20));
      expect(result.totalTokens, lessThanOrEqualTo(30));
    });

    test('recallConfig is accessible for observability', () async {
      final store = InMemoryMemoryStore();
      final config = RecallConfig(ftsWeight: 2.0, vectorWeight: 3.0);
      final engine = Souvenir(
        components: [],
        store: store,
        recallConfig: config,
      );

      expect(engine.recallConfig.ftsWeight, 2.0);
      expect(engine.recallConfig.vectorWeight, 3.0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Post-consolidation embeddings
  // ══════════════════════════════════════════════════════════════════════════

  group('Post-consolidation embeddings', () {
    test('generates embeddings for new memories', () async {
      final store = InMemoryMemoryStore();
      final embeddings = FakeEmbeddingProvider({
        'rabbit': [0.9, 0.1, 0.0, 0.0],
        'dart': [0.0, 0.0, 0.9, 0.1],
      });

      final comp = TestComponent(
        name: 'durable',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'User loves rabbits as pets',
            component: 'durable',
            category: 'fact',
            importance: 0.8,
          ),
          StoredMemory(
            content: 'Project uses Dart language',
            component: 'durable',
            category: 'fact',
            importance: 0.7,
          ),
        ],
      );

      final engine = Souvenir(
        components: [comp],
        store: store,
        embeddings: embeddings,
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      // Both memories should now have embeddings.
      final embedded = await store.loadActiveWithEmbeddings();
      expect(embedded, hasLength(2));
    });

    test('no embeddings without provider', () async {
      final store = InMemoryMemoryStore();
      final comp = TestComponent(
        name: 'task',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'Task without embeddings',
            component: 'task',
            category: 'goal',
            importance: 0.8,
          ),
        ],
      );

      final engine = Souvenir(
        components: [comp],
        store: store,
        // No embeddings provider.
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      final embedded = await store.loadActiveWithEmbeddings();
      expect(embedded, isEmpty);

      final unembedded = await store.findUnembeddedMemories();
      expect(unembedded, hasLength(1));
    });

    test('embedding failure is non-fatal', () async {
      final store = InMemoryMemoryStore();
      final failingEmbeddings = _FailingEmbeddingProvider();

      final comp = TestComponent(
        name: 'task',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'Memory that fails to embed',
            component: 'task',
            category: 'goal',
            importance: 0.8,
          ),
        ],
      );

      final engine = Souvenir(
        components: [comp],
        store: store,
        embeddings: failingEmbeddings,
      );
      await engine.initialize();

      await engine.record(_episode('test'));

      // Should not throw.
      final reports = await engine.consolidate(_noopLlm);
      expect(reports, hasLength(1));
      expect(reports.first.itemsCreated, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Full integration: consolidate + recall
  // ══════════════════════════════════════════════════════════════════════════

  group('Full integration', () {
    test('vector recall finds semantically related memories', () async {
      final store = InMemoryMemoryStore();
      final embeddings = FakeEmbeddingProvider({
        'rabbit': [0.9, 0.1, 0.0, 0.0],
        'favourite animal': [0.8, 0.2, 0.0, 0.0],
        'dart': [0.0, 0.0, 0.9, 0.1],
      });

      final comp = TestComponent(
        name: 'durable',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'User thinks rabbits are the cutest animals',
            component: 'durable',
            category: 'fact',
            importance: 0.9,
          ),
          StoredMemory(
            content: 'Project uses Dart programming language',
            component: 'durable',
            category: 'fact',
            importance: 0.7,
          ),
        ],
      );

      final engine = Souvenir(
        components: [comp],
        store: store,
        embeddings: embeddings,
      );
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      // Query by semantic meaning — should find rabbits via vector similarity.
      final result = await engine.recall('favourite animal');

      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('rabbits'));
      // Dart should rank lower (less relevant vector).
      if (result.items.length > 1) {
        expect(result.items.first.score, greaterThan(result.items.last.score));
      }
    });

    test('entity graph enhances recall', () async {
      final store = InMemoryMemoryStore();

      // Manually set up entity graph + memories (simulating durable component).
      await store.initialize();

      final rabbitEntity = Entity(name: 'rabbits', type: 'animal');
      final petEntity = Entity(name: 'pets', type: 'concept');
      await store.upsertEntity(rabbitEntity);
      await store.upsertEntity(petEntity);
      await store.upsertRelationship(Relationship(
        fromEntity: rabbitEntity.id,
        toEntity: petEntity.id,
        relation: 'is_a',
        confidence: 0.95,
      ));

      await store.insert(StoredMemory(
        content: 'User has three rabbits at home',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
        entityIds: [rabbitEntity.id],
      ));

      await store.insert(StoredMemory(
        content: 'Dart SDK version is 3.7',
        component: 'durable',
        category: 'fact',
        importance: 0.6,
      ));

      final engine = Souvenir(components: [], store: store);
      await engine.initialize();

      // Query for "rabbits" — entity graph should boost the rabbit memory.
      final result = await engine.recall('rabbits');
      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('rabbits'));
      expect(result.items.first.entitySignal, greaterThan(0));
    });

    test('score breakdown is available', () async {
      final store = InMemoryMemoryStore();

      final comp = TestComponent(
        name: 'task',
        store: store,
        itemsToCreate: [
          StoredMemory(
            content: 'Building REST API endpoints',
            component: 'task',
            category: 'goal',
            importance: 0.8,
          ),
        ],
      );

      final engine = Souvenir(components: [comp], store: store);
      await engine.initialize();

      await engine.record(_episode('test'));
      await engine.consolidate(_noopLlm);

      final result = await engine.recall('REST API');
      expect(result.items, hasLength(1));

      final item = result.items.first;
      expect(item.ftsSignal, greaterThan(0));
      expect(item.score, greaterThan(0));
      expect(item.tokens, greaterThan(0));
      expect(item.component, 'task');
      expect(item.category, 'goal');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ApproximateTokenizer
  // ══════════════════════════════════════════════════════════════════════════

  group('ApproximateTokenizer', () {
    const tokenizer = ApproximateTokenizer();

    test('empty string returns 0', () {
      expect(tokenizer.count(''), 0);
    });

    test('single character returns 1', () {
      expect(tokenizer.count('a'), 1);
    });

    test('4 characters returns 1', () {
      expect(tokenizer.count('abcd'), 1);
    });

    test('100 characters returns 25', () {
      expect(tokenizer.count('a' * 100), 25);
    });
  });
}

// ── Test doubles ─────────────────────────────────────────────────────────────

class _FailingEmbeddingProvider implements EmbeddingProvider {
  @override
  int get dimensions => 4;

  @override
  Future<List<double>> embed(String text) async {
    throw Exception('Embedding service unavailable');
  }
}
