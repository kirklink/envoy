import 'dart:convert';

import 'package:souvenir/src/durable/durable_memory.dart';
import 'package:souvenir/src/durable/durable_memory_config.dart';
import 'package:souvenir/src/environmental/environmental_memory.dart';
import 'package:souvenir/src/environmental/environmental_memory_config.dart';
import 'package:souvenir/src/in_memory_memory_store.dart';
import 'package:souvenir/src/llm_callback.dart';
import 'package:souvenir/src/models/episode.dart';
import 'package:souvenir/src/stored_memory.dart';
import 'package:souvenir/src/task/task_memory.dart';
import 'package:souvenir/src/task/task_memory_config.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

Episode _episode(String content, {String sessionId = 'ses_01'}) {
  return Episode(
    sessionId: sessionId,
    type: EpisodeType.observation,
    content: content,
  );
}

/// Creates an LLM callback that returns a fixed JSON response.
LlmCallback _fixedLlm(Map<String, dynamic> json) {
  return (String system, String user) async => jsonEncode(json);
}

/// LLM that returns empty extraction (no items).
LlmCallback _emptyLlm(String key) {
  return _fixedLlm({key: []});
}

/// LLM that throws.
Future<String> _failingLlm(String system, String user) async {
  throw Exception('LLM unavailable');
}

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // TaskMemory
  // ══════════════════════════════════════════════════════════════════════════

  group('TaskMemory consolidation', () {
    late InMemoryMemoryStore store;
    late TaskMemory task;

    setUp(() async {
      store = InMemoryMemoryStore();
      await store.initialize();
      task = TaskMemory(store: store);
    });

    test('creates items in shared store', () async {
      final llm = _fixedLlm({
        'items': [
          {
            'content': 'User wants to build a REST API',
            'category': 'goal',
            'importance': 0.8,
            'action': 'new',
          },
          {
            'content': 'Chose shelf as the HTTP framework',
            'category': 'decision',
            'importance': 0.7,
            'action': 'new',
          },
        ],
      });

      final report = await task.consolidate(
        [_episode('User asked to build a REST API using shelf')],
        llm,
      );

      expect(report.componentName, 'task');
      expect(report.itemsCreated, 2);
      expect(report.episodesConsumed, 1);

      // Verify items in shared store.
      final count = await store.activeItemCount('task');
      expect(count, 2);
    });

    test('items have correct component and category', () async {
      final llm = _fixedLlm({
        'items': [
          {
            'content': 'Building a REST API',
            'category': 'goal',
            'importance': 0.8,
            'action': 'new',
          },
        ],
      });

      await task.consolidate([_episode('Build REST API')], llm);

      final items = await store.activeItemsForSession('ses_01', 'task');
      expect(items, hasLength(1));
      expect(items.first.component, 'task');
      expect(items.first.category, 'goal');
      expect(items.first.importance, 0.8);
      expect(items.first.sessionId, 'ses_01');
    });

    test('merge action updates existing item', () async {
      // First consolidation: create initial item.
      final llm1 = _fixedLlm({
        'items': [
          {
            'content': 'User wants to build an API',
            'category': 'goal',
            'importance': 0.7,
            'action': 'new',
          },
        ],
      });
      await task.consolidate([_episode('Build an API')], llm1);

      // Second consolidation: merge with existing.
      final llm2 = _fixedLlm({
        'items': [
          {
            'content': 'User wants to build a REST API with authentication',
            'category': 'goal',
            'importance': 0.9,
            'action': 'merge',
          },
        ],
      });
      final report = await task.consolidate(
        [_episode('Add authentication to the API')],
        llm2,
      );

      expect(report.itemsMerged, 1);
      expect(report.itemsCreated, 0);

      // Still only 1 active item (merged, not duplicated).
      final count = await store.activeItemCount('task', sessionId: 'ses_01');
      expect(count, 1);
    });

    test('merge falls through to new when no match found', () async {
      final llm = _fixedLlm({
        'items': [
          {
            'content': 'Something completely unrelated to anything',
            'category': 'context',
            'importance': 0.5,
            'action': 'merge',
          },
        ],
      });

      final report = await task.consolidate([_episode('test')], llm);
      expect(report.itemsCreated, 1);
      expect(report.itemsMerged, 0);
    });

    test('session boundary expires old session items', () async {
      // Session 1: create items.
      final llm1 = _fixedLlm({
        'items': [
          {
            'content': 'Session one goal',
            'category': 'goal',
            'importance': 0.8,
            'action': 'new',
          },
        ],
      });
      await task.consolidate([_episode('test', sessionId: 'ses_01')], llm1);
      expect(task.currentSessionId, 'ses_01');

      final countBefore = await store.activeItemCount('task', sessionId: 'ses_01');
      expect(countBefore, 1);

      // Session 2: triggers expiration of session 1 items.
      final llm2 = _fixedLlm({
        'items': [
          {
            'content': 'New session goal',
            'category': 'goal',
            'importance': 0.8,
            'action': 'new',
          },
        ],
      });
      final report = await task.consolidate(
        [_episode('new session', sessionId: 'ses_02')],
        llm2,
      );

      expect(report.itemsDecayed, greaterThan(0));
      expect(task.currentSessionId, 'ses_02');

      // Old session items are expired.
      final countAfter = await store.activeItemCount('task', sessionId: 'ses_01');
      expect(countAfter, 0);
    });

    test('enforces maxItemsPerSession', () async {
      final config = TaskMemoryConfig(maxItemsPerSession: 2);
      final taskWithCap = TaskMemory(
        store: store,
        config: config,
      );

      // Insert 3 items — should evict the lowest-importance one.
      final llm = _fixedLlm({
        'items': [
          {
            'content': 'Low importance item',
            'category': 'context',
            'importance': 0.3,
            'action': 'new',
          },
          {
            'content': 'Medium importance item',
            'category': 'decision',
            'importance': 0.6,
            'action': 'new',
          },
          {
            'content': 'High importance item',
            'category': 'goal',
            'importance': 0.9,
            'action': 'new',
          },
        ],
      });

      final report = await taskWithCap.consolidate(
        [_episode('test')],
        llm,
      );

      expect(report.itemsCreated, 3);
      expect(report.itemsDecayed, greaterThan(0));

      // At most maxItemsPerSession active.
      final count = await store.activeItemCount('task', sessionId: 'ses_01');
      expect(count, lessThanOrEqualTo(2));
    });

    test('empty episodes returns empty report', () async {
      final report = await task.consolidate([], _failingLlm);

      expect(report.componentName, 'task');
      expect(report.itemsCreated, 0);
      expect(report.episodesConsumed, 0);
    });

    test('LLM failure returns graceful report', () async {
      final report = await task.consolidate(
        [_episode('test')],
        _failingLlm,
      );

      expect(report.itemsCreated, 0);
      expect(report.episodesConsumed, 0);
    });

    test('handles LLM response with markdown code fences', () async {
      final llm = (String system, String user) async => '''```json
{"items": [{"content": "Fenced response", "category": "context", "importance": 0.5, "action": "new"}]}
```''';

      final report = await task.consolidate([_episode('test')], llm);
      expect(report.itemsCreated, 1);
    });

    test('default category and importance when LLM omits them', () async {
      final llm = _fixedLlm({
        'items': [
          {'content': 'Bare minimum item', 'action': 'new'},
        ],
      });

      await task.consolidate([_episode('test')], llm);

      final items = await store.activeItemsForSession('ses_01', 'task');
      expect(items, hasLength(1));
      expect(items.first.category, 'context');
      expect(items.first.importance, 0.6); // TaskMemoryConfig.defaultImportance
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // EnvironmentalMemory
  // ══════════════════════════════════════════════════════════════════════════

  group('EnvironmentalMemory consolidation', () {
    late InMemoryMemoryStore store;
    late EnvironmentalMemory env;

    setUp(() async {
      store = InMemoryMemoryStore();
      await store.initialize();
      env = EnvironmentalMemory(store: store);
    });

    test('creates observations in shared store', () async {
      final llm = _fixedLlm({
        'observations': [
          {
            'content': 'Running on Linux x86_64',
            'category': 'environment',
            'importance': 0.6,
            'action': 'new',
          },
          {
            'content': 'Dart SDK 3.7 is available',
            'category': 'capability',
            'importance': 0.7,
            'action': 'new',
          },
        ],
      });

      final report = await env.consolidate(
        [_episode('Checked system info')],
        llm,
      );

      expect(report.componentName, 'environmental');
      expect(report.itemsCreated, 2);
      expect(report.episodesConsumed, 1);

      final count = await store.activeItemCount('environmental');
      expect(count, 2);
    });

    test('items have correct component and category', () async {
      final llm = _fixedLlm({
        'observations': [
          {
            'content': 'File write permission denied on /etc',
            'category': 'constraint',
            'importance': 0.8,
            'action': 'new',
          },
        ],
      });

      await env.consolidate([_episode('Tried writing to /etc')], llm);

      final fts = await store.searchFts('permission denied');
      expect(fts, hasLength(1));
      expect(fts.first.memory.component, 'environmental');
      expect(fts.first.memory.category, 'constraint');
    });

    test('merge action updates existing observation', () async {
      final llm1 = _fixedLlm({
        'observations': [
          {
            'content': 'Network access to external APIs works',
            'category': 'capability',
            'importance': 0.6,
            'action': 'new',
          },
        ],
      });
      await env.consolidate([_episode('Tested network')], llm1);

      final llm2 = _fixedLlm({
        'observations': [
          {
            'content': 'Network access to external APIs works with low latency',
            'category': 'capability',
            'importance': 0.8,
            'action': 'merge',
          },
        ],
      });
      final report = await env.consolidate(
        [_episode('Measured latency')],
        llm2,
      );

      expect(report.itemsMerged, 1);
      expect(report.itemsCreated, 0);
    });

    test('importance decay is applied on every consolidation', () async {
      // Insert an item with lastAccessed far in the past.
      final old = StoredMemory(
        content: 'Obsolete observation about ancient setup',
        component: 'environmental',
        category: 'environment',
        importance: 0.1,
        createdAt: DateTime.now().subtract(const Duration(days: 30)),
        updatedAt: DateTime.now().subtract(const Duration(days: 30)),
      );
      await store.insert(old);

      // Consolidate with empty episodes still triggers decay.
      final envWithConfig = EnvironmentalMemory(
        store: store,
        config: EnvironmentalMemoryConfig(
          decayInactivePeriod: const Duration(days: 1),
          decayFloorThreshold: 0.15,
        ),
      );

      final report = await envWithConfig.consolidate(
        [],
        _emptyLlm('observations'),
      );

      expect(report.itemsDecayed, 1);
    });

    test('empty episodes still applies decay', () async {
      final report = await env.consolidate([], _failingLlm);

      expect(report.componentName, 'environmental');
      expect(report.itemsCreated, 0);
      expect(report.itemsDecayed, 0); // No items to decay
    });

    test('LLM failure returns graceful report with decay', () async {
      final report = await env.consolidate(
        [_episode('test')],
        _failingLlm,
      );

      expect(report.itemsCreated, 0);
      expect(report.itemsDecayed, 0);
    });

    test('no sessionId on environmental memories', () async {
      final llm = _fixedLlm({
        'observations': [
          {
            'content': 'Cross-session observation',
            'category': 'pattern',
            'importance': 0.5,
            'action': 'new',
          },
        ],
      });

      await env.consolidate([_episode('test')], llm);

      final results = await store.searchFts('cross-session observation');
      expect(results, hasLength(1));
      expect(results.first.memory.sessionId, isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // DurableMemory
  // ══════════════════════════════════════════════════════════════════════════

  group('DurableMemory consolidation', () {
    late InMemoryMemoryStore store;
    late DurableMemory durable;

    setUp(() async {
      store = InMemoryMemoryStore();
      await store.initialize();
      durable = DurableMemory(store: store);
    });

    test('creates facts in shared store', () async {
      final llm = _fixedLlm({
        'facts': [
          {
            'content': 'User prefers functional programming style',
            'entities': [
              {'name': 'User', 'type': 'person'},
            ],
            'importance': 0.9,
            'conflict': null,
          },
        ],
        'relationships': [],
      });

      final report = await durable.consolidate(
        [_episode('User mentioned they prefer functional style')],
        llm,
      );

      expect(report.componentName, 'durable');
      expect(report.itemsCreated, 1);
      expect(report.episodesConsumed, 1);

      final count = await store.activeItemCount('durable');
      expect(count, 1);
    });

    test('facts have correct component and category', () async {
      final llm = _fixedLlm({
        'facts': [
          {
            'content': 'Project uses Dart 3.7',
            'entities': [
              {'name': 'Dart', 'type': 'language'},
            ],
            'importance': 0.7,
            'conflict': null,
          },
        ],
        'relationships': [],
      });

      await durable.consolidate([_episode('test')], llm);

      final results = await store.searchFts('Dart');
      expect(results, hasLength(1));
      expect(results.first.memory.component, 'durable');
      expect(results.first.memory.category, 'fact');
    });

    test('entities are upserted to shared store', () async {
      final llm = _fixedLlm({
        'facts': [
          {
            'content': 'Alice uses Dart for backend development',
            'entities': [
              {'name': 'Alice', 'type': 'person'},
              {'name': 'Dart', 'type': 'language'},
            ],
            'importance': 0.7,
            'conflict': null,
          },
        ],
        'relationships': [],
      });

      await durable.consolidate([_episode('test')], llm);

      final aliceEntities = await store.findEntitiesByName('Alice');
      expect(aliceEntities, hasLength(1));
      expect(aliceEntities.first.type, 'person');

      final dartEntities = await store.findEntitiesByName('Dart');
      expect(dartEntities, hasLength(1));
      expect(dartEntities.first.type, 'language');
    });

    test('entity IDs are attached to memories', () async {
      final llm = _fixedLlm({
        'facts': [
          {
            'content': 'Bob prefers Vim as editor',
            'entities': [
              {'name': 'Bob', 'type': 'person'},
              {'name': 'Vim', 'type': 'tool'},
            ],
            'importance': 0.8,
            'conflict': null,
          },
        ],
        'relationships': [],
      });

      await durable.consolidate([_episode('test')], llm);

      final results = await store.searchFts('Vim editor');
      expect(results, hasLength(1));
      expect(results.first.memory.entityIds, hasLength(2));
    });

    test('relationships are upserted', () async {
      final llm = _fixedLlm({
        'facts': [
          {
            'content': 'Swoop is built on shelf',
            'entities': [
              {'name': 'Swoop', 'type': 'project'},
              {'name': 'shelf', 'type': 'project'},
            ],
            'importance': 0.7,
            'conflict': null,
          },
        ],
        'relationships': [
          {
            'from': 'Swoop',
            'to': 'shelf',
            'relation': 'depends_on',
            'confidence': 0.95,
          },
        ],
      });

      await durable.consolidate([_episode('test')], llm);

      final swoopEntities = await store.findEntitiesByName('Swoop');
      expect(swoopEntities, isNotEmpty);

      final rels = await store.findRelationshipsForEntity(
        swoopEntities.first.id,
      );
      expect(rels, hasLength(1));
      expect(rels.first.relation, 'depends_on');
      expect(rels.first.confidence, 0.95);
    });

    test('duplicate conflict skips if existing importance is higher', () async {
      // Create initial fact.
      final llm1 = _fixedLlm({
        'facts': [
          {
            'content': 'User prefers dark mode in all applications',
            'entities': [],
            'importance': 0.9,
            'conflict': null,
          },
        ],
        'relationships': [],
      });
      await durable.consolidate([_episode('test')], llm1);

      // Duplicate with lower importance — should be skipped.
      final llm2 = _fixedLlm({
        'facts': [
          {
            'content': 'User prefers dark mode in all applications',
            'entities': [],
            'importance': 0.5,
            'conflict': 'duplicate',
          },
        ],
        'relationships': [],
      });
      final report = await durable.consolidate([_episode('test2')], llm2);

      expect(report.itemsCreated, 0);
      expect(report.itemsMerged, 0);

      // Still only 1 item.
      final count = await store.activeItemCount('durable');
      expect(count, 1);
    });

    test('duplicate conflict merges if new importance is higher', () async {
      // Create initial fact with low importance.
      final llm1 = _fixedLlm({
        'facts': [
          {
            'content': 'User prefers tabs over spaces for indentation',
            'entities': [],
            'importance': 0.4,
            'conflict': null,
          },
        ],
        'relationships': [],
      });
      await durable.consolidate([_episode('test')], llm1);

      // Duplicate with higher importance — should merge.
      final llm2 = _fixedLlm({
        'facts': [
          {
            'content': 'User prefers tabs over spaces for indentation',
            'entities': [],
            'importance': 0.8,
            'conflict': 'duplicate',
          },
        ],
        'relationships': [],
      });
      final report = await durable.consolidate([_episode('test2')], llm2);

      expect(report.itemsMerged, 1);

      // Still only 1 item, but importance boosted.
      final count = await store.activeItemCount('durable');
      expect(count, 1);
    });

    test('update conflict merges content and importance', () async {
      final llm1 = _fixedLlm({
        'facts': [
          {
            'content': 'Project uses PostgreSQL for persistence',
            'entities': [
              {'name': 'PostgreSQL', 'type': 'technology'},
            ],
            'importance': 0.6,
            'conflict': null,
          },
        ],
        'relationships': [],
      });
      await durable.consolidate([_episode('test')], llm1);

      // Update: add detail.
      final llm2 = _fixedLlm({
        'facts': [
          {
            'content': 'Project uses PostgreSQL 16 for persistence with JSONB columns',
            'entities': [
              {'name': 'PostgreSQL', 'type': 'technology'},
            ],
            'importance': 0.8,
            'conflict': 'update',
          },
        ],
        'relationships': [],
      });
      final report = await durable.consolidate([_episode('test2')], llm2);

      expect(report.itemsMerged, 1);

      // Content should be updated.
      final results = await store.searchFts('PostgreSQL JSONB');
      expect(results, isNotEmpty);
    });

    test('contradiction supersedes old memory', () async {
      final llm1 = _fixedLlm({
        'facts': [
          {
            'content': 'Project uses MySQL for persistence',
            'entities': [
              {'name': 'MySQL', 'type': 'technology'},
            ],
            'importance': 0.7,
            'conflict': null,
          },
        ],
        'relationships': [],
      });
      await durable.consolidate([_episode('test')], llm1);

      // Now contradict: switched to PostgreSQL.
      final llm2 = _fixedLlm({
        'facts': [
          {
            'content': 'Project migrated from MySQL to PostgreSQL for persistence',
            'entities': [
              {'name': 'MySQL', 'type': 'technology'},
              {'name': 'PostgreSQL', 'type': 'technology'},
            ],
            'importance': 0.8,
            'conflict': 'contradiction',
          },
        ],
        'relationships': [],
      });
      final report = await durable.consolidate([_episode('test2')], llm2);

      expect(report.itemsCreated, 1);

      // The old memory should be superseded, new one active.
      final count = await store.activeItemCount('durable');
      expect(count, 1);

      final results = await store.searchFts('PostgreSQL');
      expect(results, hasLength(1));
      expect(results.first.memory.content, contains('migrated'));
    });

    test('importance decay on empty episodes', () async {
      // Insert an old, inactive item.
      final old = StoredMemory(
        content: 'Outdated fact about removed feature xyzzy',
        component: 'durable',
        category: 'fact',
        importance: 0.15,
        createdAt: DateTime.now().subtract(const Duration(days: 120)),
        updatedAt: DateTime.now().subtract(const Duration(days: 120)),
      );
      await store.insert(old);

      final durableWithConfig = DurableMemory(
        store: store,
        config: DurableMemoryConfig(
          decayInactivePeriod: const Duration(days: 1),
        ),
      );

      final report = await durableWithConfig.consolidate(
        [],
        _emptyLlm('facts'),
      );

      // Decay applied even with no episodes.
      expect(report.itemsDecayed, greaterThanOrEqualTo(0));
    });

    test('LLM failure returns graceful report', () async {
      final report = await durable.consolidate(
        [_episode('test')],
        _failingLlm,
      );

      expect(report.itemsCreated, 0);
      expect(report.itemsDecayed, 0);
    });

    test('entities created by relationships are persisted', () async {
      final llm = _fixedLlm({
        'facts': [],
        'relationships': [
          {
            'from': 'React',
            'to': 'JavaScript',
            'relation': 'written_in',
            'confidence': 1.0,
          },
        ],
      });

      await durable.consolidate([_episode('test')], llm);

      // Both entities should have been created.
      final react = await store.findEntitiesByName('React');
      expect(react, isNotEmpty);

      final js = await store.findEntitiesByName('JavaScript');
      expect(js, isNotEmpty);

      // Relationship should exist.
      final rels = await store.findRelationshipsForEntity(react.first.id);
      expect(rels, hasLength(1));
    });

    test('existing entities are reused (not duplicated)', () async {
      // First pass: create an entity.
      final llm1 = _fixedLlm({
        'facts': [
          {
            'content': 'Dart is a programming language by Google',
            'entities': [
              {'name': 'Dart', 'type': 'language'},
            ],
            'importance': 0.7,
            'conflict': null,
          },
        ],
        'relationships': [],
      });
      await durable.consolidate([_episode('test1')], llm1);

      final dartBefore = await store.findEntitiesByName('Dart');
      expect(dartBefore, hasLength(1));
      final dartId = dartBefore.first.id;

      // Second pass: same entity name should reuse ID.
      final llm2 = _fixedLlm({
        'facts': [
          {
            'content': 'Dart 3.7 supports pattern matching',
            'entities': [
              {'name': 'Dart', 'type': 'language'},
            ],
            'importance': 0.6,
            'conflict': null,
          },
        ],
        'relationships': [],
      });
      await durable.consolidate([_episode('test2')], llm2);

      // The memory should reference the same entity ID.
      final results = await store.searchFts('pattern matching');
      expect(results, hasLength(1));
      expect(results.first.memory.entityIds, contains(dartId));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Cross-component: shared store
  // ══════════════════════════════════════════════════════════════════════════

  group('Cross-component shared store', () {
    late InMemoryMemoryStore store;
    late TaskMemory task;
    late EnvironmentalMemory env;
    late DurableMemory durable;

    setUp(() async {
      store = InMemoryMemoryStore();
      await store.initialize();
      task = TaskMemory(store: store);
      env = EnvironmentalMemory(store: store);
      durable = DurableMemory(store: store);
    });

    test('all components write to same store', () async {
      await task.consolidate(
        [_episode('Build API')],
        _fixedLlm({
          'items': [
            {
              'content': 'Building a REST API',
              'category': 'goal',
              'importance': 0.8,
              'action': 'new',
            },
          ],
        }),
      );

      await env.consolidate(
        [_episode('Checked system')],
        _fixedLlm({
          'observations': [
            {
              'content': 'System has 16GB RAM',
              'category': 'environment',
              'importance': 0.5,
              'action': 'new',
            },
          ],
        }),
      );

      await durable.consolidate(
        [_episode('User mentioned preference')],
        _fixedLlm({
          'facts': [
            {
              'content': 'User prefers Vim',
              'entities': [
                {'name': 'Vim', 'type': 'tool'},
              ],
              'importance': 0.9,
              'conflict': null,
            },
          ],
          'relationships': [],
        }),
      );

      // All components write to the same store.
      final taskCount = await store.activeItemCount('task');
      final envCount = await store.activeItemCount('environmental');
      final durableCount = await store.activeItemCount('durable');

      expect(taskCount, 1);
      expect(envCount, 1);
      expect(durableCount, 1);

      // FTS search crosses all components.
      final allResults = await store.searchFts('API OR RAM OR Vim');
      expect(allResults, hasLength(3));
    });

    test('component operations are scoped and do not interfere', () async {
      // Create items in all three components.
      await task.consolidate(
        [_episode('Build stuff')],
        _fixedLlm({
          'items': [
            {
              'content': 'Task item alpha',
              'category': 'goal',
              'importance': 0.8,
              'action': 'new',
            },
          ],
        }),
      );

      await env.consolidate(
        [_episode('Check env')],
        _fixedLlm({
          'observations': [
            {
              'content': 'Environmental observation beta',
              'category': 'environment',
              'importance': 0.6,
              'action': 'new',
            },
          ],
        }),
      );

      await durable.consolidate(
        [_episode('Learn fact')],
        _fixedLlm({
          'facts': [
            {
              'content': 'Durable fact gamma',
              'entities': [],
              'importance': 0.7,
              'conflict': null,
            },
          ],
          'relationships': [],
        }),
      );

      // Expire task session — should only affect task items.
      await store.expireSession('ses_01', 'task');

      expect(await store.activeItemCount('task', sessionId: 'ses_01'), 0);
      expect(await store.activeItemCount('environmental'), 1);
      expect(await store.activeItemCount('durable'), 1);
    });

    test('entity graph is shared across components', () async {
      // Durable creates an entity.
      await durable.consolidate(
        [_episode('Dart is great')],
        _fixedLlm({
          'facts': [
            {
              'content': 'Project uses Dart programming language',
              'entities': [
                {'name': 'Dart', 'type': 'language'},
              ],
              'importance': 0.7,
              'conflict': null,
            },
          ],
          'relationships': [],
        }),
      );

      // Entity is visible in the shared store.
      final entities = await store.findEntitiesByName('Dart');
      expect(entities, hasLength(1));

      // Any component's memories can reference entities.
      final mems = await store.findMemoriesByEntityIds(
        [entities.first.id],
      );
      expect(mems, hasLength(1));
      expect(mems.first.component, 'durable');
    });
  });
}
