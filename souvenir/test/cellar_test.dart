import 'package:cellar/cellar.dart';
import 'package:souvenir/src/cellar_episode_store.dart';
import 'package:souvenir/src/models/episode.dart';
import 'package:souvenir/src/souvenir_cellar.dart';
import 'package:souvenir/src/sqlite_memory_store.dart';
import 'package:souvenir/src/stored_memory.dart';
import 'package:test/test.dart';

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // CellarEpisodeStore
  // ══════════════════════════════════════════════════════════════════════════

  group('CellarEpisodeStore', () {
    late Cellar cellar;
    late CellarEpisodeStore store;

    setUp(() {
      cellar = Cellar.memory(
        collections: [SouvenirCellar.episodesCollection('')],
      );
      store = CellarEpisodeStore(cellar, 'episodes');
    });

    tearDown(() {
      cellar.close();
    });

    test('insert and fetch unconsolidated', () async {
      final episodes = [
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.observation,
          content: 'User typed a command',
        ),
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.toolResult,
          content: 'Tool returned results',
        ),
      ];

      await store.insert(episodes);

      expect(store.count, 2);
      expect(store.unconsolidatedCount, 2);

      final fetched = await store.fetchUnconsolidated();
      expect(fetched, hasLength(2));
      expect(fetched[0].content, 'User typed a command');
      expect(fetched[0].type, EpisodeType.observation);
      expect(fetched[0].sessionId, 'ses_01');
      expect(fetched[0].consolidated, isFalse);
    });

    test('mark consolidated', () async {
      final episodes = [
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.observation,
          content: 'Test episode',
        ),
      ];

      await store.insert(episodes);
      expect(store.unconsolidatedCount, 1);

      await store.markConsolidated(episodes);
      expect(store.unconsolidatedCount, 0);
      expect(store.count, 1);
    });

    test('fetch unconsolidated returns empty when all consolidated', () async {
      final episodes = [
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.observation,
          content: 'Already consolidated',
        ),
      ];

      await store.insert(episodes);
      await store.markConsolidated(episodes);

      final fetched = await store.fetchUnconsolidated();
      expect(fetched, isEmpty);
    });

    test('insert empty list is no-op', () async {
      await store.insert([]);
      expect(store.count, 0);
    });

    test('mark consolidated with empty list is no-op', () async {
      await store.markConsolidated([]);
      // No error thrown.
    });

    test('preserves episode fields', () async {
      final ep = Episode(
        sessionId: 'ses_42',
        type: EpisodeType.toolResult,
        content: 'Detailed result content',
        importance: 0.8,
      );

      await store.insert([ep]);
      final fetched = await store.fetchUnconsolidated();

      expect(fetched, hasLength(1));
      expect(fetched.first.sessionId, 'ses_42');
      expect(fetched.first.type, EpisodeType.toolResult);
      expect(fetched.first.content, 'Detailed result content');
      expect(fetched.first.importance, 0.8);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SouvenirCellar
  // ══════════════════════════════════════════════════════════════════════════

  group('SouvenirCellar', () {
    test('creates episode store', () {
      final cellar = Cellar.memory();
      final sc = SouvenirCellar(cellar: cellar);

      final episodeStore = sc.createEpisodeStore();
      expect(episodeStore, isA<CellarEpisodeStore>());

      cellar.close();
    });

    test('creates unified memory store', () {
      final cellar = Cellar.memory();
      final sc = SouvenirCellar(cellar: cellar);

      final memoryStore = sc.createMemoryStore();
      expect(memoryStore, isA<SqliteMemoryStore>());

      cellar.close();
    });

    test('multi-agent prefix isolation', () async {
      final cellar = Cellar.memory();

      final agent1 = SouvenirCellar(cellar: cellar, agentId: 'researcher');
      final agent2 = SouvenirCellar(cellar: cellar, agentId: 'coder');

      expect(agent1.prefix, 'researcher_');
      expect(agent2.prefix, 'coder_');

      expect(agent1.collectionName('episodes'), 'researcher_episodes');
      expect(agent2.collectionName('episodes'), 'coder_episodes');

      // Each agent's memory store operates independently.
      final store1 = agent1.createMemoryStore();
      final store2 = agent2.createMemoryStore();
      await store1.initialize();
      await store2.initialize();

      // Data written by agent 1 should not appear in agent 2's store.
      await store1.insert(_testMemory('Rabbits are wonderful pets'));
      await store2.insert(_testMemory('PostgreSQL database optimization'));

      final fts1 = await store1.searchFts('rabbits');
      final fts2 = await store2.searchFts('PostgreSQL');
      expect(fts1, hasLength(1));
      expect(fts2, hasLength(1));

      // Cross-check: agent 1 should not see agent 2's data.
      final cross = await store1.searchFts('PostgreSQL');
      expect(cross, isEmpty);

      cellar.close();
    });

    test('empty agentId produces no prefix', () {
      final cellar = Cellar.memory();
      final sc = SouvenirCellar(cellar: cellar, agentId: '');

      expect(sc.prefix, '');
      expect(sc.collectionName('episodes'), 'episodes');

      cellar.close();
    });

    test('encryption enforcement throws on unencrypted DB', () {
      final cellar = Cellar.memory();

      expect(
        () => SouvenirCellar(
          cellar: cellar,
          requireEncryption: true,
        ),
        throwsStateError,
      );

      cellar.close();
    });

    test('no encryption enforcement by default', () {
      final cellar = Cellar.memory();

      // Should not throw.
      final sc = SouvenirCellar(cellar: cellar);
      expect(sc, isNotNull);

      cellar.close();
    });

    test('episode store round-trip via SouvenirCellar', () async {
      final cellar = Cellar.memory();
      final sc = SouvenirCellar(cellar: cellar, agentId: 'test');

      final episodeStore = sc.createEpisodeStore();

      await episodeStore.insert([
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.observation,
          content: 'Round-trip test',
        ),
      ]);

      final fetched = await episodeStore.fetchUnconsolidated();
      expect(fetched, hasLength(1));
      expect(fetched.first.content, 'Round-trip test');

      cellar.close();
    });

    test('end-to-end: SouvenirCellar stores → recall', () async {
      final cellar = Cellar.memory();
      final sc = SouvenirCellar(cellar: cellar, agentId: 'agent');

      final memoryStore = sc.createMemoryStore();
      await memoryStore.initialize();

      // Insert a memory directly (simulating post-consolidation).
      await memoryStore.insert(_testMemory('User prefers dark mode'));

      final results = await memoryStore.searchFts('dark mode');
      expect(results, hasLength(1));
      expect(results.first.memory.content, 'User prefers dark mode');

      cellar.close();
    });
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

StoredMemory _testMemory(String content) {
  return StoredMemory(
    content: content,
    component: 'durable',
    category: 'fact',
    importance: 0.7,
  );
}
