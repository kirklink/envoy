import 'package:test/test.dart';

import 'package:souvenir/src/embedding_provider.dart';
import 'package:souvenir/src/in_memory_memory_store.dart';
import 'package:souvenir/src/recall.dart';
import 'package:souvenir/src/recall_profiles.dart';
import 'package:souvenir/src/stored_memory.dart';
import 'package:souvenir/src/tokenizer.dart';

/// Deterministic embedding fake keyed by exact text.
class MapEmbeddings implements EmbeddingProvider {
  final Map<String, List<double>> vectors;
  MapEmbeddings(this.vectors);

  @override
  int get dimensions => 4;

  @override
  Future<List<double>> embed(String text) async {
    return vectors[text] ?? [0.0, 0.0, 0.0, 1.0];
  }
}

void main() {
  late InMemoryMemoryStore store;
  const tokenizer = ApproximateTokenizer();

  setUp(() async {
    store = InMemoryMemoryStore();
    await store.initialize();

    await store.insert(StoredMemory(
      content: 'Current goal is fixing the Dart parser bug',
      component: 'task',
      category: 'goal',
      importance: 0.7,
      sessionId: 'ses1',
    ));
    await store.insert(StoredMemory(
      content: 'User prefers the Dart language for backend work',
      component: 'durable',
      category: 'preference',
      importance: 0.7,
    ));
    await store.insert(StoredMemory(
      content: 'Dart SDK 3.7 installed on this machine',
      component: 'environmental',
      category: 'capability',
      importance: 0.7,
    ));
  });

  UnifiedRecall makeRecall(RecallConfig config) => UnifiedRecall(
        store: store,
        tokenizer: tokenizer,
        config: config,
      );

  group('excludeComponents', () {
    test('excluded component never appears in results', () async {
      final recall = makeRecall(const RecallConfig(
        relevanceThreshold: 0.01,
        excludeComponents: {'environmental'},
      ));

      final result = await recall.recall('Dart');
      expect(result.items, isNotEmpty);
      expect(
        result.items.map((i) => i.component),
        everyElement(isNot(equals('environmental'))),
      );
    });

    test('empty exclusion returns all components', () async {
      final recall = makeRecall(const RecallConfig(relevanceThreshold: 0.01));

      final result = await recall.recall('Dart');
      expect(
        result.items.map((i) => i.component).toSet(),
        equals({'task', 'durable', 'environmental'}),
      );
    });
  });

  group('categoryWeights', () {
    test('boosted category outranks equal-signal competitors', () async {
      final baseline = makeRecall(const RecallConfig(relevanceThreshold: 0.01));
      final boosted = makeRecall(const RecallConfig(
        relevanceThreshold: 0.01,
        categoryWeights: {'goal': 3.0},
      ));

      final baseResult = await baseline.recall('Dart');
      final boostResult = await boosted.recall('Dart');

      expect(baseResult.items.first.category, isNot(equals('goal')),
          reason: 'without boost, the goal memory should not lead (longer '
              'text than the capability memory, same importance)');
      expect(boostResult.items.first.category, equals('goal'));
    });
  });

  group('per-call config override', () {
    test('override applies for one call only', () async {
      final recall = makeRecall(const RecallConfig(relevanceThreshold: 0.01));

      final overridden = await recall.recall(
        'Dart',
        config: const RecallConfig(
          relevanceThreshold: 0.01,
          excludeComponents: {'task', 'durable'},
        ),
      );
      expect(
        overridden.items.map((i) => i.component).toSet(),
        equals({'environmental'}),
      );

      // Next call without an override reverts to the instance config.
      final normal = await recall.recall('Dart');
      expect(
        normal.items.map((i) => i.component).toSet(),
        equals({'task', 'durable', 'environmental'}),
      );
    });
  });

  group('RecallConfig.copyWith', () {
    test('replaces only the given fields', () {
      const base = RecallConfig(vectorNoiseFloor: 0.3, topK: 7);
      final copy = base.copyWith(topK: 3);

      expect(copy.topK, equals(3));
      expect(copy.vectorNoiseFloor, equals(0.3));
      expect(copy.ftsWeight, equals(base.ftsWeight));
    });
  });

  group('RecallProfiles', () {
    test('profiles multiply into existing component weights', () {
      const base = RecallConfig(componentWeights: {'durable': 1.2});
      final profiled = RecallProfiles.durableFocus(base);

      expect(profiled.componentWeights['durable'], closeTo(1.8, 1e-9));
      expect(profiled.componentWeights['task'], closeTo(0.8, 1e-9));
      // Non-weight settings are untouched.
      expect(profiled.vectorNoiseFloor, equals(base.vectorNoiseFloor));
      expect(profiled.relevanceThreshold, equals(base.relevanceThreshold));
    });

    test('profile changes which component wins a tied query', () async {
      final base = makeRecall(const RecallConfig(relevanceThreshold: 0.01));
      final baseTop = (await base.recall('Dart')).items.first;

      final taskBiased = await base.recall(
        'Dart',
        config: RecallProfiles.taskFocus(
          const RecallConfig(relevanceThreshold: 0.01),
        ),
      );
      expect(taskBiased.items.first.component, equals('task'));

      final envBiased = await base.recall(
        'Dart',
        config: RecallProfiles.environmentFocus(
          const RecallConfig(relevanceThreshold: 0.01),
        ),
      );
      expect(envBiased.items.first.component, equals('environmental'));

      // Sanity: the unbiased winner is stable across the overridden calls.
      final baseAgain = (await base.recall('Dart')).items.first;
      expect(baseAgain.component, equals(baseTop.component));
    });
  });

  group('HeuristicQueryClassifier', () {
    final classifier = HeuristicQueryClassifier();

    test('classifies task-status queries', () {
      expect(classifier.classify('what task am I currently working on'),
          equals(QueryIntent.taskStatus));
      expect(classifier.classify('what is the next goal'),
          equals(QueryIntent.taskStatus));
    });

    test('classifies fact-lookup queries', () {
      expect(classifier.classify('what does the user prefer for backend'),
          equals(QueryIntent.factLookup));
      expect(classifier.classify('who is Alice'),
          equals(QueryIntent.factLookup));
    });

    test('classifies capability queries', () {
      expect(classifier.classify('which SDK version is installed'),
          equals(QueryIntent.capability));
      expect(classifier.classify('what platform is this system running'),
          equals(QueryIntent.capability));
    });

    test('falls back to general on no signal or ties', () {
      expect(classifier.classify('rabbits'), equals(QueryIntent.general));
      // 'goal' (task) and 'prefers' (fact) tie 1-1.
      expect(classifier.classify('goal prefers'), equals(QueryIntent.general));
    });

    test('profileFor applies the matching profile', () {
      const base = RecallConfig();
      final profiled = classifier.profileFor('current task progress', base);
      expect(profiled.componentWeights['task'], closeTo(1.5, 1e-9));
    });
  });
}
