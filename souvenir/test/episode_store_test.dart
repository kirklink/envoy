import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

import 'package:souvenir/src/episode_store.dart';
import 'package:souvenir/src/models/episode.dart';
import 'package:souvenir/src/sqlite_episode_store.dart';

void main() {
  // Run the same contract suite against both implementations.
  group('InMemoryEpisodeStore', () {
    _episodeStoreTests(() async => InMemoryEpisodeStore());
  });

  group('SqliteEpisodeStore', () {
    _episodeStoreTests(() async {
      final db = sqlite3.sqlite3.openInMemory();
      final store = SqliteEpisodeStore(db);
      await store.initialize();
      return store;
    });
  });

  group('SqliteEpisodeStore (prefixed)', () {
    _episodeStoreTests(() async {
      final db = sqlite3.sqlite3.openInMemory();
      final store = SqliteEpisodeStore(db, prefix: 'agent1_');
      await store.initialize();
      return store;
    });
  });

  group('SqliteEpisodeStore persistence', () {
    test('round-trips all episode fields', () async {
      final db = sqlite3.sqlite3.openInMemory();
      final store = SqliteEpisodeStore(db);
      await store.initialize();

      final episode = Episode(
        sessionId: 'ses1',
        type: EpisodeType.userDirective,
        content: 'Always use the staging database for tests',
        importance: 0.95,
      );
      await store.insert([episode]);

      final fetched = (await store.fetchUnconsolidated()).single;
      expect(fetched.id, equals(episode.id));
      expect(fetched.sessionId, equals('ses1'));
      expect(fetched.type, equals(EpisodeType.userDirective));
      expect(fetched.content, equals(episode.content));
      expect(fetched.importance, equals(0.95));
      expect(fetched.consolidated, isFalse);
      expect(
        fetched.timestamp.toUtc().toIso8601String(),
        equals(episode.timestamp.toUtc().toIso8601String()),
      );
    });

    test('shares a database with SqliteMemoryStore table names', () async {
      final db = sqlite3.sqlite3.openInMemory();
      final store = SqliteEpisodeStore(db);
      await store.initialize();

      // The memory store creates memories/entities/relationships; the
      // episode table must not collide.
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'])
          .toList();
      expect(tables, contains('episodes'));
      expect(tables, isNot(contains('memories')));
    });
  });
}

void _episodeStoreTests(Future<EpisodeStore> Function() createStore) {
  late EpisodeStore store;

  setUp(() async {
    store = await createStore();
  });

  Episode makeEpisode(String content, {String session = 'ses1'}) => Episode(
        sessionId: session,
        type: EpisodeType.conversation,
        content: content,
      );

  test('insert and fetchUnconsolidated returns inserted episodes', () async {
    await store.insert([makeEpisode('one'), makeEpisode('two')]);

    final unconsolidated = await store.fetchUnconsolidated();
    expect(unconsolidated, hasLength(2));
    expect(
      unconsolidated.map((e) => e.content),
      containsAll(['one', 'two']),
    );
  });

  test('fetchUnconsolidated is empty for a fresh store', () async {
    expect(await store.fetchUnconsolidated(), isEmpty);
  });

  test('markConsolidated removes episodes from the unconsolidated set',
      () async {
    final a = makeEpisode('alpha');
    final b = makeEpisode('beta');
    await store.insert([a, b]);

    await store.markConsolidated([a]);

    final remaining = await store.fetchUnconsolidated();
    expect(remaining, hasLength(1));
    expect(remaining.single.content, equals('beta'));
  });

  test('markConsolidated with empty list is a no-op', () async {
    await store.insert([makeEpisode('one')]);
    await store.markConsolidated([]);
    expect(await store.fetchUnconsolidated(), hasLength(1));
  });

  test('deleteConsolidatedBefore prunes only old consolidated episodes',
      () async {
    final old = Episode(
      sessionId: 'ses1',
      type: EpisodeType.observation,
      content: 'old consolidated',
      timestamp: DateTime.utc(2020, 1, 1),
    );
    final recent = makeEpisode('recent consolidated');
    final unconsolidated = Episode(
      sessionId: 'ses1',
      type: EpisodeType.observation,
      content: 'old but unconsolidated',
      timestamp: DateTime.utc(2020, 1, 1),
    );
    await store.insert([old, recent, unconsolidated]);
    await store.markConsolidated([old, recent]);

    final removed = await store.deleteConsolidatedBefore(
      DateTime.utc(2021, 1, 1),
    );

    expect(removed, equals(1));
    // The old-but-unconsolidated episode survives.
    final remaining = await store.fetchUnconsolidated();
    expect(remaining.single.content, equals('old but unconsolidated'));
  });
}
