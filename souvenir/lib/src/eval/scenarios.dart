import '../embedding_provider.dart';
import '../memory_store.dart';
import '../stored_memory.dart';
import 'types.dart';

// ── Embedding provider ────────────────────────────────────────────────────────

/// Fake embedding provider with manually-assigned semantic cluster vectors.
///
/// Used when no real embedding provider is configured (fast, deterministic).
/// Vectors are 5-dimensional: [animals, programming, database, general, unrelated].
/// The 5th "unrelated" dimension is orthogonal to all topic clusters, ensuring
/// that queries about unrelated topics (quantum physics, medieval history) have
/// zero cosine similarity with any stored memory.
/// Cosine similarity between cluster members ≈ 0.95-0.99.
class EvalEmbeddingProvider implements EmbeddingProvider {
  static const _vectors = <String, List<double>>{
    // Animal cluster
    'rabbits': [0.95, 0.0, 0.0, 0.05, 0.0],
    'rabbit': [0.95, 0.0, 0.0, 0.05, 0.0],
    'cute animals': [0.9, 0.0, 0.0, 0.1, 0.0],
    'favourite animal': [0.9, 0.0, 0.0, 0.1, 0.0],
    'pets': [0.85, 0.0, 0.0, 0.15, 0.0],
    'animals': [0.88, 0.0, 0.0, 0.12, 0.0],
    // Programming cluster
    'Dart': [0.0, 0.95, 0.0, 0.05, 0.0],
    'programming': [0.0, 0.9, 0.0, 0.1, 0.0],
    'Dart language': [0.0, 0.92, 0.0, 0.08, 0.0],
    'code patterns': [0.0, 0.8, 0.0, 0.2, 0.0],
    'software development': [0.0, 0.85, 0.05, 0.1, 0.0],
    // Database cluster
    'PostgreSQL': [0.0, 0.1, 0.9, 0.0, 0.0],
    'database': [0.0, 0.1, 0.85, 0.05, 0.0],
    'sqlite': [0.0, 0.1, 0.85, 0.05, 0.0],
    'SQL queries': [0.0, 0.15, 0.8, 0.05, 0.0],
    'data persistence': [0.0, 0.1, 0.8, 0.1, 0.0],
    // Mixed / general
    'project setup': [0.0, 0.4, 0.3, 0.3, 0.0],
    'authentication': [0.0, 0.3, 0.2, 0.5, 0.0],
    'REST API': [0.0, 0.6, 0.2, 0.2, 0.0],
    'HTTP framework': [0.0, 0.65, 0.1, 0.25, 0.0],
    // Unrelated (orthogonal to all topic clusters)
    'quantum entanglement': [0.0, 0.0, 0.0, 0.0, 1.0],
    'medieval history': [0.0, 0.0, 0.0, 0.0, 1.0],
  };

  @override
  int get dimensions => 5;

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
    // Default: general cluster (orthogonal to unrelated).
    return [0.0, 0.0, 0.0, 1.0, 0.0];
  }
}

// ── Shared seed helpers ───────────────────────────────────────────────────────

/// Seeds the standard "project context" memory set used by most scenarios.
///
/// Creates 10 memories across durable/task/environmental components, plus
/// 4 entities and 2 relationships, then embeds everything with [embeddings].
Future<_SeedRefs> _seedStandard(
  MemoryStore store,
  EmbeddingProvider embedder,
) async {
  final rabbit = Entity(name: 'rabbits', type: 'animal');
  final dart = Entity(name: 'Dart', type: 'language');
  final pg = Entity(name: 'PostgreSQL', type: 'technology');
  final alice = Entity(name: 'Alice', type: 'person');

  await store.upsertEntity(rabbit);
  await store.upsertEntity(dart);
  await store.upsertEntity(pg);
  await store.upsertEntity(alice);

  await store.upsertRelationship(Relationship(
    fromEntity: alice.id,
    toEntity: rabbit.id,
    relation: 'owns',
    confidence: 0.9,
  ));
  await store.upsertRelationship(Relationship(
    fromEntity: dart.id,
    toEntity: pg.id,
    relation: 'connects_to',
    confidence: 0.7,
  ));

  // Durable memories.
  await store.insert(StoredMemory(
    content: 'User thinks rabbits are the most adorable creatures',
    component: 'durable',
    category: 'fact',
    importance: 0.9,
    entityIds: [rabbit.id],
  ));
  await store.insert(StoredMemory(
    content: 'Project uses Dart 3.7 as the primary language',
    component: 'durable',
    category: 'fact',
    importance: 0.7,
    entityIds: [dart.id],
  ));
  await store.insert(StoredMemory(
    content: 'PostgreSQL 16 is the production database with JSONB columns',
    component: 'durable',
    category: 'fact',
    importance: 0.8,
    entityIds: [pg.id],
  ));
  await store.insert(StoredMemory(
    content: 'Alice is the project lead and prefers pair programming',
    component: 'durable',
    category: 'fact',
    importance: 0.7,
    entityIds: [alice.id],
  ));
  await store.insert(StoredMemory(
    content: 'User prefers dark mode in all development tools',
    component: 'durable',
    category: 'fact',
    importance: 0.6,
  ));

  // Task memories.
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

  // Environmental memories.
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
    entityIds: [dart.id],
  ));

  // Embed everything.
  final unembedded = await store.findUnembeddedMemories(limit: 100);
  for (final mem in unembedded) {
    final vector = await embedder.embed(mem.content);
    await store.update(mem.id, embedding: vector);
  }

  return _SeedRefs(
    rabbitId: rabbit.id,
    dartId: dart.id,
    pgId: pg.id,
    aliceId: alice.id,
  );
}

class _SeedRefs {
  final String rabbitId;
  final String dartId;
  final String pgId;
  final String aliceId;
  const _SeedRefs({
    required this.rabbitId,
    required this.dartId,
    required this.pgId,
    required this.aliceId,
  });
}

// ── Scenario definitions ─────────────────────────────────────────────────────

/// All built-in evaluation scenarios.
final List<EvalScenario> defaultScenarios = [
  // 1. Semantic bridge ──────────────────────────────────────────────────────
  EvalScenario(
    name: 'semantic_bridge',
    description:
        'Queries with no keyword overlap must bridge to memories via vector '
        'similarity. The classic failure mode of pure FTS-based recall.',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();
      await _seedStandard(store, embedder);
    },
    queries: const [
      EvalQuery(
        query: 'favourite animal',
        expectedTopFragment: 'rabbits',
        description: '"favourite animal" → rabbit memory via vector (no FTS match)',
      ),
      EvalQuery(
        query: 'cute pets',
        expectedTopFragment: 'rabbits',
        description: '"cute pets" → rabbit memory via vector similarity',
      ),
      EvalQuery(
        query: 'preferred programming language',
        expectedTopFragment: 'Dart',
        description: '"preferred programming language" → Dart memory via vector',
      ),
    ],
  ),

  // 2. FTS direct ───────────────────────────────────────────────────────────
  EvalScenario(
    name: 'fts_direct',
    description:
        'Queries with direct keyword overlap rely primarily on BM25 FTS signal.',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();
      await _seedStandard(store, embedder);
    },
    queries: const [
      EvalQuery(
        query: 'REST API',
        expectedTopFragment: 'REST API endpoints',
        description: '"REST API" → task goal via exact FTS match',
      ),
      EvalQuery(
        query: 'JWT tokens',
        expectedTopFragment: 'JWT tokens',
        description: '"JWT tokens" → authentication result via FTS',
      ),
      EvalQuery(
        query: 'PostgreSQL JSONB',
        expectedTopFragment: 'PostgreSQL 16',
        description: '"PostgreSQL JSONB" → durable fact via FTS',
      ),
    ],
  ),

  // 3. Entity expansion ─────────────────────────────────────────────────────
  EvalScenario(
    name: 'entity_expansion',
    description:
        'Querying for an entity name should expand to memories linked via '
        'the entity graph, including 1-hop relationships.',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();
      await _seedStandard(store, embedder);
    },
    queries: const [
      EvalQuery(
        query: 'Alice',
        expectedTopFragment: 'Alice',
        description: '"Alice" → memory about Alice via entity match',
      ),
      EvalQuery(
        query: 'rabbits',
        expectedTopFragment: 'rabbits',
        description: '"rabbits" → rabbit memory via entity + FTS signals',
      ),
    ],
  ),

  // 4. Multi-signal reinforcement ───────────────────────────────────────────
  EvalScenario(
    name: 'multi_signal',
    description:
        'Memories matching on multiple signals (FTS + entity + vector) should '
        'rank above single-signal matches for the same query.',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();
      await _seedStandard(store, embedder);
    },
    queries: const [
      EvalQuery(
        query: 'Dart language',
        expectedTopFragment: 'Dart 3.7',
        description:
            '"Dart language" → durable Dart fact ranks above env Dart via '
            'multi-signal (FTS + entity + importance)',
      ),
      EvalQuery(
        query: 'database queries',
        expectedTopFragment: 'PostgreSQL 16',
        description:
            '"database queries" → PostgreSQL memory via FTS + entity + vector',
      ),
    ],
  ),

  // 5. Component weights ────────────────────────────────────────────────────
  EvalScenario(
    name: 'component_weights',
    description:
        'When default component weights are used, durable facts (importance '
        '0.7-0.9) should outrank lower-importance environmental observations '
        'for the same topic.',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();
      await _seedStandard(store, embedder);
    },
    queries: const [
      EvalQuery(
        query: 'Dart',
        expectedTopFragment: 'Dart 3.7 as the primary language',
        description:
            'Durable "Dart 3.7 as primary language" (importance 0.7) outranks '
            'environmental "Dart SDK installed" (importance 0.6)',
      ),
    ],
  ),

  // 6. Temporal decay ───────────────────────────────────────────────────────
  EvalScenario(
    name: 'temporal_decay',
    description:
        'A recent memory with the same content should rank above an old '
        'memory with the same importance, due to temporal decay.',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();

      // Old memory (120 days ago).
      final old = StoredMemory(
        content: 'Preferred database is PostgreSQL',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
        createdAt: DateTime.now().subtract(const Duration(days: 120)),
        updatedAt: DateTime.now().subtract(const Duration(days: 120)),
      );
      // Recent memory (same content, same importance, created now).
      final recent = StoredMemory(
        content: 'Preferred database is PostgreSQL',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      );

      await store.insert(old);
      await store.insert(recent);

      for (final mem in [old, recent]) {
        final vector = await embedder.embed(mem.content);
        await store.update(mem.id, embedding: vector);
      }
    },
    queries: const [
      EvalQuery(
        query: 'preferred database',
        expectedTopFragment: 'Preferred database is PostgreSQL',
        description:
            'Recent memory should rank at position 1 (temporal decay penalises '
            'the 120-day-old duplicate)',
      ),
    ],
  ),

  // 7. Relevance silence ────────────────────────────────────────────────────
  EvalScenario(
    name: 'relevance_silence',
    description:
        'Completely unrelated queries should return no results above the '
        'relevance threshold (silence > noise).',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();
      await _seedStandard(store, embedder);
    },
    queries: const [
      EvalQuery(
        query: 'quantum entanglement',
        expectedTopFragment: '__NO_MATCH__',
        description:
            '"quantum entanglement" should return empty (no relevant memories)',
      ),
      EvalQuery(
        query: 'medieval history knights',
        expectedTopFragment: '__NO_MATCH__',
        description:
            '"medieval history" should return empty (irrelevant to project context)',
      ),
    ],
  ),

  // 8. Conversation pipeline ─────────────────────────────────────────────────
  EvalScenario(
    name: 'conversation_pipeline',
    description:
        'Simulates a multi-turn conversation: the store is seeded with '
        'memories that would have been consolidated from a realistic exchange '
        '(discussing a project, then an unrelated topic). Recall should '
        'surface the right memories despite topic mixing.',
    setup: (store, embeddings) async {
      final embedder = embeddings ?? EvalEmbeddingProvider();

      // Turn 1-3: technical discussion.
      await store.insert(StoredMemory(
        content: 'User is building a task management CLI in Dart',
        component: 'task',
        category: 'goal',
        importance: 0.85,
        sessionId: 'ses_conv',
      ));
      await store.insert(StoredMemory(
        content: 'Chose sqlite3 package for local persistence',
        component: 'task',
        category: 'decision',
        importance: 0.75,
        sessionId: 'ses_conv',
      ));
      await store.insert(StoredMemory(
        content: 'User knows Dart well but is new to SQLite',
        component: 'durable',
        category: 'fact',
        importance: 0.8,
      ));
      await store.insert(StoredMemory(
        content: 'SQLite WAL mode enabled for concurrent reads',
        component: 'environmental',
        category: 'capability',
        importance: 0.6,
      ));

      // Turn 4-5: rabbit tangent.
      await store.insert(StoredMemory(
        content: 'User owns two rabbits named Mochi and Daisy',
        component: 'durable',
        category: 'fact',
        importance: 0.7,
      ));
      await store.insert(StoredMemory(
        content: 'User feeds rabbits pellets and hay twice a day',
        component: 'durable',
        category: 'fact',
        importance: 0.5,
      ));

      // Embed everything.
      final unembedded = await store.findUnembeddedMemories(limit: 100);
      for (final mem in unembedded) {
        final vector = await embedder.embed(mem.content);
        await store.update(mem.id, embedding: vector);
      }
    },
    queries: const [
      EvalQuery(
        query: 'what are we building',
        expectedTopFragment: 'task management CLI',
        description: 'Project goal surfaces despite rabbit tangent in history',
      ),
      EvalQuery(
        query: 'database choice',
        expectedTopFragment: 'sqlite3',
        description: 'Technical decision recalled correctly',
      ),
      EvalQuery(
        query: 'rabbit names',
        expectedTopFragment: 'Mochi',
        description: 'Off-topic personal fact recalled when directly queried',
      ),
      EvalQuery(
        query: 'experience with SQLite and Dart',
        expectedTopFragment: 'Dart well',
        description:
            'Durable user-knowledge fact surfaces via FTS overlap ("Dart", "SQLite")',
      ),
    ],
  ),
];

// ── Special handling: "no match expected" queries ─────────────────────────────

/// Sentinel value used in [EvalQuery.expectedTopFragment] to indicate that
/// a query is expected to return zero results.
const kExpectEmpty = '__NO_MATCH__';
