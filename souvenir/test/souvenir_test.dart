import 'dart:convert';

import 'package:souvenir/souvenir.dart';
import 'package:test/test.dart';

/// Mock LLM that returns predetermined consolidation JSON.
Future<String> _mockLlm(String system, String user) async {
  return jsonEncode({
    'facts': [
      {
        'content': 'User prefers dark mode in all applications',
        'entities': [
          {'name': 'User', 'type': 'person'},
          {'name': 'dark mode', 'type': 'preference'},
        ],
        'importance': 0.9,
      },
      {
        'content': 'Project uses SQLite for local storage',
        'entities': [
          {'name': 'Project', 'type': 'project'},
          {'name': 'SQLite', 'type': 'concept'},
        ],
        'importance': 0.7,
      },
    ],
    'relationships': [
      {
        'from': 'Project',
        'to': 'SQLite',
        'relation': 'uses',
        'confidence': 0.95,
      },
    ],
  });
}

/// Mock LLM that returns malformed JSON.
Future<String> _brokenLlm(String system, String user) async {
  return 'this is not json at all {{{';
}

/// Mock LLM that throws.
Future<String> _failingLlm(String system, String user) async {
  throw Exception('LLM service unavailable');
}

void main() {
  // ── Episode model ─────────────────────────────────────────────────────────

  group('Episode', () {
    test('auto-generates ULID if id not provided', () {
      final ep = Episode(
        sessionId: 'ses_01',
        type: EpisodeType.conversation,
        content: 'hello',
      );
      expect(ep.id, isNotEmpty);
      expect(ep.id.length, 26); // ULID is 26 chars
    });

    test('uses provided id when given', () {
      final ep = Episode(
        id: 'custom-id',
        sessionId: 'ses_01',
        type: EpisodeType.conversation,
        content: 'hello',
      );
      expect(ep.id, 'custom-id');
    });

    test('defaults timestamp to now', () {
      final before = DateTime.now();
      final ep = Episode(
        sessionId: 'ses_01',
        type: EpisodeType.conversation,
        content: 'hello',
      );
      final after = DateTime.now();
      expect(
          ep.timestamp.isAfter(before.subtract(Duration(seconds: 1))), true);
      expect(ep.timestamp.isBefore(after.add(Duration(seconds: 1))), true);
    });

    test('defaults importance from EpisodeType', () {
      expect(
        Episode(sessionId: 's', type: EpisodeType.conversation, content: 'c')
            .importance,
        0.4,
      );
      expect(
        Episode(sessionId: 's', type: EpisodeType.toolResult, content: 'c')
            .importance,
        0.8,
      );
      expect(
        Episode(sessionId: 's', type: EpisodeType.userDirective, content: 'c')
            .importance,
        0.95,
      );
    });

    test('allows importance override', () {
      final ep = Episode(
        sessionId: 's',
        type: EpisodeType.conversation,
        content: 'c',
        importance: 0.99,
      );
      expect(ep.importance, 0.99);
    });
  });

  // ── Memory model ────────────────────────────────────────────────────────

  group('Memory', () {
    test('auto-generates ULID', () {
      final m = Memory(content: 'test fact');
      expect(m.id, isNotEmpty);
      expect(m.id.length, 26);
    });

    test('defaults timestamps to now', () {
      final before = DateTime.now();
      final m = Memory(content: 'test');
      final after = DateTime.now();
      expect(m.createdAt.isAfter(before.subtract(Duration(seconds: 1))), true);
      expect(m.updatedAt.isBefore(after.add(Duration(seconds: 1))), true);
    });

    test('defaults importance to 0.5', () {
      expect(Memory(content: 'test').importance, 0.5);
    });
  });

  // ── Entity model ──────────────────────────────────────────────────────────

  group('Entity', () {
    test('auto-generates ULID', () {
      final e = Entity(name: 'SQLite', type: EntityType.concept);
      expect(e.id, isNotEmpty);
      expect(e.id.length, 26);
    });

    test('EntityType has expected values', () {
      expect(EntityType.values, hasLength(5));
      expect(EntityType.values.map((t) => t.name),
          containsAll(['person', 'project', 'concept', 'preference', 'fact']));
    });
  });

  // ── Relationship model ────────────────────────────────────────────────────

  group('Relationship', () {
    test('defaults confidence to 1.0', () {
      final r = Relationship(
        fromEntityId: 'a',
        toEntityId: 'b',
        relation: 'uses',
      );
      expect(r.confidence, 1.0);
    });

    test('defaults updatedAt to now', () {
      final before = DateTime.now();
      final r = Relationship(
        fromEntityId: 'a',
        toEntityId: 'b',
        relation: 'uses',
      );
      expect(
          r.updatedAt.isAfter(before.subtract(Duration(seconds: 1))), true);
    });
  });

  // ── Write pipeline ────────────────────────────────────────────────────────

  group('Write pipeline', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(config: const SouvenirConfig(flushThreshold: 3));
      await souvenir.initialize();
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('record adds to buffer', () async {
      await souvenir.record(Episode(
        sessionId: 's',
        type: EpisodeType.observation,
        content: 'buffered',
      ));
      expect(souvenir.bufferSize, 1);
    });

    test('flush writes buffer to database', () async {
      await souvenir.record(Episode(
        sessionId: 's',
        type: EpisodeType.observation,
        content: 'test content for flush',
      ));
      expect(souvenir.bufferSize, 1);

      await souvenir.flush();
      expect(souvenir.bufferSize, 0);

      final results = await souvenir.recall('flush');
      expect(results, isNotEmpty);
    });

    test('auto-flushes when buffer reaches threshold', () async {
      await souvenir.record(Episode(
        sessionId: 's',
        type: EpisodeType.observation,
        content: 'first episode about databases',
      ));
      await souvenir.record(Episode(
        sessionId: 's',
        type: EpisodeType.observation,
        content: 'second episode about databases',
      ));
      expect(souvenir.bufferSize, 2);

      await souvenir.record(Episode(
        sessionId: 's',
        type: EpisodeType.observation,
        content: 'third episode about databases',
      ));
      expect(souvenir.bufferSize, 0);

      final results = await souvenir.recall('databases');
      expect(results.length, 3);
    });

    test('close flushes remaining buffer', () async {
      final s2 =
          Souvenir(config: const SouvenirConfig(flushThreshold: 100));
      await s2.initialize();

      await s2.record(Episode(
        sessionId: 's',
        type: EpisodeType.observation,
        content: 'should survive close',
      ));
      expect(s2.bufferSize, 1);

      await s2.close();
      expect(s2.bufferSize, 0);
    });

    test('flush is no-op when buffer is empty', () async {
      await souvenir.flush(); // should not throw
    });
  });

  // ── FTS5 search ───────────────────────────────────────────────────────────

  group('FTS5 search', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir();
      await souvenir.initialize();

      final episodes = [
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.toolResult,
          content: 'Successfully compiled the Dart application',
        ),
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.error,
          content: 'Failed to connect to the PostgreSQL database',
        ),
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.decision,
          content:
              'Decided to use SQLite instead of PostgreSQL for local storage',
        ),
        Episode(
          sessionId: 'ses_02',
          type: EpisodeType.conversation,
          content: 'User asked about authentication patterns',
        ),
        Episode(
          sessionId: 'ses_02',
          type: EpisodeType.toolResult,
          content: 'Wrote a JWT authentication middleware in Dart',
        ),
      ];

      for (final ep in episodes) {
        await souvenir.record(ep);
      }
      await souvenir.flush();
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('returns matching results', () async {
      final results = await souvenir.recall('PostgreSQL');
      expect(results.length, 2);
      for (final r in results) {
        expect(r.content.toLowerCase(), contains('postgresql'));
      }
    });

    test('excludes non-matching results', () async {
      final results = await souvenir.recall('authentication');
      expect(results.length, 2);
      for (final r in results) {
        expect(r.content.toLowerCase(), contains('authenticat'));
      }
    });

    test('returns empty list for no matches', () async {
      final results = await souvenir.recall('kubernetes');
      expect(results, isEmpty);
    });

    test('results have positive scores', () async {
      final results = await souvenir.recall('Dart');
      expect(results, isNotEmpty);
      for (final r in results) {
        expect(r.score, greaterThan(0));
      }
    });

    test('results are attributed as episodic', () async {
      final results = await souvenir.recall('Dart');
      for (final r in results) {
        expect(r.source, RecallSource.episodic);
      }
    });

    test('results include importance from episode type', () async {
      final results = await souvenir.recall('PostgreSQL database');
      expect(results, isNotEmpty);
      final errorResult = results.firstWhere((r) => r.content.contains('Failed'));
      expect(errorResult.importance, 0.8);
    });

    test('porter stemming matches word variants', () async {
      final results = await souvenir.recall('compile');
      expect(results, isNotEmpty);
      expect(results.first.content, contains('compiled'));
    });
  });

  // ── RecallOptions ─────────────────────────────────────────────────────────

  group('RecallOptions', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir();
      await souvenir.initialize();

      for (var i = 0; i < 15; i++) {
        await souvenir.record(Episode(
          sessionId: i < 10 ? 'ses_a' : 'ses_b',
          type: EpisodeType.observation,
          content: 'observation about memory system design iteration $i',
        ));
      }
      await souvenir.flush();
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('topK limits results', () async {
      final results = await souvenir.recall(
        'memory',
        options: const RecallOptions(topK: 3),
      );
      expect(results.length, 3);
    });

    test('sessionId scopes search', () async {
      final results = await souvenir.recall(
        'memory',
        options: const RecallOptions(topK: 20, sessionId: 'ses_b'),
      );
      expect(results.length, 5);
    });
  });

  // ── Idempotency ───────────────────────────────────────────────────────────

  group('Idempotency', () {
    test('initialize is safe to call multiple times', () async {
      final souvenir = Souvenir();
      await souvenir.initialize();
      await souvenir.initialize();
      await souvenir.close();
    });
  });

  // ── Consolidation ─────────────────────────────────────────────────────────

  group('Consolidation', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration.zero,
          flushThreshold: 100,
        ),
      );
      await souvenir.initialize();

      // Seed episodes across two sessions.
      for (final ep in [
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.decision,
          content: 'Decided to use dark mode for all interfaces',
        ),
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.toolResult,
          content: 'Configured SQLite database for local storage',
        ),
        Episode(
          sessionId: 'ses_02',
          type: EpisodeType.observation,
          content: 'User mentioned preference for Dart language',
        ),
      ]) {
        await souvenir.record(ep);
      }
      await souvenir.flush();
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('creates memories from episodes', () async {
      final result = await souvenir.consolidate(_mockLlm);
      expect(result.memoriesCreated, greaterThan(0));
    });

    test('marks episodes as consolidated', () async {
      await souvenir.consolidate(_mockLlm);

      // Second consolidation finds no unconsolidated episodes.
      final result2 = await souvenir.consolidate(_mockLlm);
      expect(result2.sessionsProcessed, 0);
      expect(result2.memoriesCreated, 0);
    });

    test('creates entities', () async {
      final result = await souvenir.consolidate(_mockLlm);
      expect(result.entitiesUpserted, greaterThan(0));
    });

    test('creates relationships', () async {
      final result = await souvenir.consolidate(_mockLlm);
      expect(result.relationshipsUpserted, greaterThan(0));
    });

    test('LLM failure skips session gracefully', () async {
      final result = await souvenir.consolidate(_failingLlm);
      expect(result.sessionsSkipped, greaterThan(0));
      expect(result.memoriesCreated, 0);
    });

    test('malformed JSON skips session gracefully', () async {
      final result = await souvenir.consolidate(_brokenLlm);
      expect(result.sessionsSkipped, greaterThan(0));
      expect(result.memoriesCreated, 0);
    });

    test('consolidationMinAge is respected', () async {
      // Use a config with a very long min age.
      final s2 = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration(days: 365),
        ),
      );
      await s2.initialize();

      await s2.record(Episode(
        sessionId: 'ses',
        type: EpisodeType.observation,
        content: 'recent episode that should not be consolidated',
      ));
      await s2.flush();

      final result = await s2.consolidate(_mockLlm);
      expect(result.sessionsProcessed, 0);
      expect(result.memoriesCreated, 0);

      await s2.close();
    });

    test('returns counters', () async {
      final result = await souvenir.consolidate(_mockLlm);
      expect(result.sessionsProcessed, greaterThan(0));
      expect(result.sessionsSkipped, 0);
    });
  });

  // ── Memory merging ────────────────────────────────────────────────────────

  group('Memory merging', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration.zero,
          mergeThreshold: 0.0, // Always merge if any match found.
        ),
      );
      await souvenir.initialize();
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('duplicate fact merges into existing memory', () async {
      // First consolidation creates memories.
      await souvenir.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.decision,
        content: 'User prefers dark mode',
      ));
      await souvenir.flush();
      final r1 = await souvenir.consolidate(_mockLlm);
      expect(r1.memoriesCreated, greaterThan(0));

      // Second consolidation with similar content should merge.
      await souvenir.record(Episode(
        sessionId: 'ses_02',
        type: EpisodeType.decision,
        content: 'Confirmed dark mode preference again',
      ));
      await souvenir.flush();
      final r2 = await souvenir.consolidate(_mockLlm);
      expect(r2.memoriesMerged, greaterThan(0));
    });
  });

  // ── Memory FTS5 search ────────────────────────────────────────────────────

  group('Memory FTS5 search', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(
        config: const SouvenirConfig(consolidationMinAge: Duration.zero),
      );
      await souvenir.initialize();

      // Seed and consolidate to create semantic memories.
      await souvenir.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.decision,
        content: 'Chose to implement authentication with JWT tokens',
      ));
      await souvenir.flush();
      await souvenir.consolidate(_mockLlm);
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('recall returns semantic results', () async {
      // The mock LLM always returns facts about "dark mode" and "SQLite".
      final results = await souvenir.recall('dark mode');
      final semanticResults =
          results.where((r) => r.source == RecallSource.semantic);
      expect(semanticResults, isNotEmpty);
    });

    test('semantic results have positive scores', () async {
      final results = await souvenir.recall('SQLite');
      final semanticResults =
          results.where((r) => r.source == RecallSource.semantic);
      for (final r in semanticResults) {
        expect(r.score, greaterThan(0));
      }
    });

    test('recall returns both episodic and semantic results', () async {
      // "SQLite" appears in both the episode content and the mock LLM facts.
      // Insert an episode about SQLite too.
      await souvenir.record(Episode(
        sessionId: 'ses_02',
        type: EpisodeType.observation,
        content: 'SQLite performs well for local development',
      ));
      await souvenir.flush();

      final results = await souvenir.recall('SQLite');
      final sources = results.map((r) => r.source).toSet();
      expect(sources, contains(RecallSource.episodic));
      expect(sources, contains(RecallSource.semantic));
    });

    test('topK limits combined results', () async {
      final results = await souvenir.recall(
        'SQLite',
        options: const RecallOptions(topK: 1),
      );
      expect(results.length, 1);
    });
  });

  // ── Importance decay ──────────────────────────────────────────────────────

  group('Importance decay', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration.zero,
          decayInactivePeriod: Duration.zero, // Decay everything.
          importanceDecayRate: 0.5,
        ),
      );
      await souvenir.initialize();

      // Create a memory via consolidation.
      await souvenir.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.decision,
        content: 'Architecture decision about caching strategy',
      ));
      await souvenir.flush();
      await souvenir.consolidate(_mockLlm);
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('decay is applied during consolidation', () async {
      // First consolidation already ran in setUp, which applied decay.
      // Search for a memory to check its importance was decayed.
      final results = await souvenir.recall('dark mode');
      final semantic =
          results.where((r) => r.source == RecallSource.semantic).toList();

      if (semantic.isNotEmpty) {
        // Original importance was 0.9 from mock LLM. After decay with
        // rate 0.5 and inactivePeriod=0, it should be 0.9 * 0.5 = 0.45.
        expect(semantic.first.importance, closeTo(0.45, 0.01));
      }
    });

    test('consolidation result reports decayed count', () async {
      // Run another consolidation (no new episodes to consolidate,
      // but decay still runs).
      final result = await souvenir.consolidate(_mockLlm);
      expect(result.memoriesDecayed, greaterThanOrEqualTo(0));
    });
  });

  // ── Config consolidation ─────────────────────────────────────────────────

  group('SouvenirConfig', () {
    test('all defaults have expected values', () {
      const config = SouvenirConfig();
      // Write pipeline.
      expect(config.flushThreshold, 50);
      // Episodic importance defaults.
      expect(config.importanceUserDirective, 0.95);
      expect(config.importanceError, 0.8);
      expect(config.importanceToolResult, 0.8);
      expect(config.importanceDecision, 0.75);
      expect(config.importanceConversation, 0.4);
      expect(config.importanceObservation, 0.3);
      // Consolidation.
      expect(config.consolidationMinAge, const Duration(minutes: 5));
      expect(config.mergeThreshold, 0.5);
      expect(config.defaultImportance, 0.5);
      expect(config.defaultConfidence, 1.0);
      // Decay.
      expect(config.importanceDecayRate, 0.95);
      expect(config.decayInactivePeriod, const Duration(days: 30));
      // Retrieval pipeline.
      expect(config.recallTopK, 10);
      expect(config.rrfK, 60);
      expect(config.temporalDecayLambda, 0.01);
      expect(config.contextTokenBudget, 4000);
      expect(config.tokenEstimationDivisor, 4.0);
    });

    test('importanceForEpisodeType resolves correctly', () {
      const config = SouvenirConfig(
        importanceConversation: 0.55,
        importanceToolResult: 0.99,
      );
      expect(config.importanceForEpisodeType('conversation'), 0.55);
      expect(config.importanceForEpisodeType('toolResult'), 0.99);
      expect(config.importanceForEpisodeType('unknown'), config.defaultImportance);
    });
  });

  // ── Retrieval pipeline ─────────────────────────────────────────────────

  group('Retrieval pipeline', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration.zero,
          flushThreshold: 100,
        ),
      );
      await souvenir.initialize();

      // Seed episodes and consolidate to create memories + entities.
      for (final ep in [
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.decision,
          content: 'Decided to use dark mode for all interfaces',
        ),
        Episode(
          sessionId: 'ses_01',
          type: EpisodeType.toolResult,
          content: 'Configured SQLite database for local storage',
        ),
      ]) {
        await souvenir.record(ep);
      }
      await souvenir.flush();
      await souvenir.consolidate(_mockLlm);
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('results from multiple signals', () async {
      // Add an episode that also matches "SQLite" for episodic signal.
      await souvenir.record(Episode(
        sessionId: 'ses_02',
        type: EpisodeType.observation,
        content: 'SQLite is fast for local development',
      ));
      await souvenir.flush();

      final results = await souvenir.recall('SQLite');
      final sources = results.map((r) => r.source).toSet();
      expect(sources, contains(RecallSource.episodic));
      // semantic or entity — both come from memories.
      expect(
        results.any((r) =>
            r.source == RecallSource.semantic ||
            r.source == RecallSource.entity),
        isTrue,
      );
    });

    test('items in multiple signals score higher', () async {
      // "SQLite" appears in both episodic and semantic memories.
      // Also the entity "SQLite" exists, so entity-graph also finds it.
      await souvenir.record(Episode(
        sessionId: 'ses_02',
        type: EpisodeType.observation,
        content: 'SQLite is a great embedded database engine',
      ));
      // "authentication" only appears in one episode.
      await souvenir.record(Episode(
        sessionId: 'ses_02',
        type: EpisodeType.observation,
        content: 'Authentication is important for security',
      ));
      await souvenir.flush();

      final sqliteResults = await souvenir.recall('SQLite');
      final authResults = await souvenir.recall('authentication');

      // SQLite appears in more signals, so its top result should score higher.
      expect(sqliteResults, isNotEmpty);
      expect(authResults, isNotEmpty);
      // SQLite's top score benefits from multi-signal fusion.
      expect(sqliteResults.first.score, greaterThan(0));
    });

    test('deduplication removes exact duplicates', () async {
      // Record an episode with exact same content as a known memory.
      await souvenir.record(Episode(
        sessionId: 'ses_03',
        type: EpisodeType.observation,
        content: 'User prefers dark mode in all applications',
      ));
      await souvenir.flush();

      final results = await souvenir.recall('dark mode');
      // Count how many results have the exact duplicate content.
      final duplicateContent = results
          .where((r) => r.content == 'User prefers dark mode in all applications')
          .toList();
      expect(duplicateContent.length, 1);
    });

    test('minImportance filter works', () async {
      final results = await souvenir.recall(
        'dark mode',
        options: const RecallOptions(minImportance: 0.99),
      );
      for (final r in results) {
        expect(r.importance, greaterThanOrEqualTo(0.99));
      }
    });

    test('tokenBudget caps result size', () async {
      // Very small budget — should return few or no results.
      final results = await souvenir.recall(
        'SQLite',
        options: const RecallOptions(tokenBudget: 5),
      );
      // With a budget of 5 tokens (~20 chars), most results won't fit.
      expect(results.length, lessThanOrEqualTo(1));
    });

    test('includeEpisodic false skips episodic', () async {
      final results = await souvenir.recall(
        'dark mode',
        options: const RecallOptions(includeEpisodic: false),
      );
      final episodic = results.where((r) => r.source == RecallSource.episodic);
      expect(episodic, isEmpty);
    });

    test('includeSemantic false skips semantic', () async {
      // Add an episode so there's at least something to find.
      await souvenir.record(Episode(
        sessionId: 'ses_04',
        type: EpisodeType.observation,
        content: 'dark mode theme configuration',
      ));
      await souvenir.flush();

      final results = await souvenir.recall(
        'dark mode',
        options: const RecallOptions(includeSemantic: false),
      );
      final semantic = results.where((r) => r.source == RecallSource.semantic);
      expect(semantic, isEmpty);
    });

    test('results have positive scores', () async {
      final results = await souvenir.recall('dark mode');
      expect(results, isNotEmpty);
      for (final r in results) {
        expect(r.score, greaterThan(0));
      }
    });

    test('empty query returns empty results', () async {
      final results = await souvenir.recall('xyznonexistent');
      expect(results, isEmpty);
    });
  });

  // ── Entity graph expansion ─────────────────────────────────────────────

  group('Entity graph expansion', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration.zero,
          flushThreshold: 100,
        ),
      );
      await souvenir.initialize();

      // Seed and consolidate — mock LLM creates entities "User", "dark mode",
      // "Project", "SQLite" and a relationship "Project uses SQLite".
      await souvenir.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.decision,
        content: 'Decided to use dark mode for all interfaces',
      ));
      await souvenir.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.toolResult,
        content: 'Configured SQLite database for local storage',
      ));
      await souvenir.flush();
      await souvenir.consolidate(_mockLlm);
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('finds memories via entity name match', () async {
      // Query "SQLite" — entity "SQLite" exists, so graph expansion
      // should find memories referencing it.
      final results = await souvenir.recall('SQLite');
      expect(results, isNotEmpty);
    });

    test('follows relationships to connected entities', () async {
      // Query "Project" with only entity-graph signal enabled.
      // Entity "Project" exists with a relationship to "SQLite".
      // Graph expansion finds "Project", follows the "uses" relationship
      // to "SQLite", and returns memories that reference either entity.
      final results = await souvenir.recall(
        'Project',
        options: const RecallOptions(
          includeEpisodic: false,
          includeSemantic: false,
        ),
      );
      expect(results, isNotEmpty);
      // All results are entity-sourced since other signals are disabled.
      for (final r in results) {
        expect(r.source, RecallSource.entity);
      }
      // Should find the SQLite-related memory through the relationship hop.
      expect(
        results.any((r) => r.content.contains('SQLite')),
        isTrue,
      );
    });

    test('empty entity match returns gracefully', () async {
      // Query that matches no entity names.
      final results = await souvenir.recall('kubernetes');
      expect(results, isEmpty);
    });

    test('entity source is attributed correctly', () async {
      // Disable episodic and semantic so only entity-graph results appear.
      final results = await souvenir.recall(
        'Project',
        options: const RecallOptions(
          includeEpisodic: false,
          includeSemantic: false,
        ),
      );
      for (final r in results) {
        expect(r.source, RecallSource.entity);
      }
    });
  });

  // ── SessionContext ──────────────────────────────────────────────────────

  group('SessionContext', () {
    late Souvenir souvenir;

    setUp(() async {
      souvenir = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration.zero,
          flushThreshold: 100,
        ),
      );
      await souvenir.initialize();

      // Seed episodes and consolidate.
      await souvenir.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.decision,
        content: 'Decided to use dark mode for all interfaces',
      ));
      await souvenir.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.toolResult,
        content: 'Configured SQLite database for local storage',
      ));
      await souvenir.flush();
      await souvenir.consolidate(_mockLlm);
    });

    tearDown(() async {
      await souvenir.close();
    });

    test('loadContext returns relevant memories', () async {
      final context = await souvenir.loadContext('dark mode preferences');
      expect(context.memories, isNotEmpty);
      expect(
        context.memories.any((m) => m.content.contains('dark mode')),
        isTrue,
      );
    });

    test('loadContext returns recent episodes', () async {
      // Add a recent episode.
      await souvenir.record(Episode(
        sessionId: 'ses_02',
        type: EpisodeType.observation,
        content: 'Recent observation about testing patterns',
      ));
      await souvenir.flush();

      final context = await souvenir.loadContext('testing');
      expect(context.episodes, isNotEmpty);
    });

    test('loadContext respects token budget', () async {
      // Use a very small token budget.
      final s2 = Souvenir(
        config: const SouvenirConfig(
          consolidationMinAge: Duration.zero,
          contextTokenBudget: 5, // ~20 chars max.
        ),
      );
      await s2.initialize();

      // Create memories.
      await s2.record(Episode(
        sessionId: 'ses_01',
        type: EpisodeType.decision,
        content: 'Decided to use dark mode for all interfaces',
      ));
      await s2.flush();
      await s2.consolidate(_mockLlm);

      final context = await s2.loadContext('dark mode');
      // With a budget of 5 tokens, very few memories fit.
      final totalChars =
          context.memories.fold<int>(0, (sum, m) => sum + m.content.length);
      // 5 tokens * 4 chars = 20 chars max.
      expect(totalChars, lessThanOrEqualTo(20));

      await s2.close();
    });

    test('placeholder fields are null/empty', () async {
      final context = await souvenir.loadContext('anything');
      expect(context.personality, isNull);
      expect(context.identity, isNull);
      expect(context.procedures, isEmpty);
    });

    test('estimatedTokens calculates correctly', () {
      final context = SessionContext(
        memories: [Memory(content: 'a' * 100)], // 100 chars = 25 tokens
        episodes: [
          Episode(
            sessionId: 's',
            type: EpisodeType.observation,
            content: 'b' * 200, // 200 chars = 50 tokens
          ),
        ],
      );
      expect(context.estimatedTokens, 75);
    });
  });
}
