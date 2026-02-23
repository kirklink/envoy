import 'dart:convert';

import 'package:souvenir/souvenir.dart';
import 'package:stanza_sqlite/stanza_sqlite.dart';
import 'package:test/test.dart';

// ── Test helpers ─────────────────────────────────────────────────────────────

/// Stub component with configurable behavior and call tracking.
class StubComponent extends MemoryComponent {
  @override
  final String name;

  bool initialized = false;
  bool closed = false;
  int consolidateCallCount = 0;
  int recallCallCount = 0;
  List<Episode>? lastConsolidationEpisodes;
  String? lastRecallQuery;
  ComponentBudget? lastConsolidationBudget;
  ComponentBudget? lastRecallBudget;

  List<LabeledRecall> recallItems;
  ConsolidationReport Function(List<Episode> episodes)? onConsolidate;
  Duration? delay;

  StubComponent({
    required this.name,
    this.recallItems = const [],
    this.onConsolidate,
    this.delay,
  });

  @override
  Future<void> initialize() async {
    if (delay != null) await Future.delayed(delay!);
    initialized = true;
  }

  @override
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
    ComponentBudget budget,
  ) async {
    if (delay != null) await Future.delayed(delay!);
    consolidateCallCount++;
    lastConsolidationEpisodes = episodes;
    lastConsolidationBudget = budget;
    if (onConsolidate != null) return onConsolidate!(episodes);
    return ConsolidationReport(
      componentName: name,
      episodesConsumed: episodes.length,
    );
  }

  @override
  Future<List<LabeledRecall>> recall(
    String query,
    ComponentBudget budget,
  ) async {
    if (delay != null) await Future.delayed(delay!);
    recallCallCount++;
    lastRecallQuery = query;
    lastRecallBudget = budget;
    return recallItems;
  }

  @override
  Future<void> close() async {
    if (delay != null) await Future.delayed(delay!);
    closed = true;
  }
}

Future<String> _noopLlm(String system, String user) async => '';

Episode _episode(String content, {String sessionId = 'ses_01'}) {
  return Episode(
    sessionId: sessionId,
    type: EpisodeType.observation,
    content: content,
  );
}

Budget _testBudget({
  int total = 1000,
  Map<String, int> allocation = const {},
  Tokenizer? tokenizer,
}) {
  return Budget(
    totalTokens: total,
    allocation: allocation,
    tokenizer: tokenizer ?? const ApproximateTokenizer(),
  );
}

Souvenir _engine({
  List<MemoryComponent>? components,
  Budget? budget,
  Mixer? mixer,
  EpisodeStore? store,
  int flushThreshold = 50,
}) {
  return Souvenir(
    components: components ?? [],
    budget: budget ?? _testBudget(),
    mixer: mixer ?? const WeightedMixer(),
    store: store,
    flushThreshold: flushThreshold,
  );
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── ApproximateTokenizer ─────────────────────────────────────────────────

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

    test('5 characters returns 2', () {
      expect(tokenizer.count('abcde'), 2);
    });

    test('100 characters returns 25', () {
      expect(tokenizer.count('a' * 100), 25);
    });

    test('whitespace counts normally', () {
      expect(tokenizer.count('    '), 1);
    });

    test('long text scales linearly', () {
      expect(tokenizer.count('x' * 10000), 2500);
    });
  });

  // ── ComponentBudget ──────────────────────────────────────────────────────

  group('ComponentBudget', () {
    test('starts with zero usedTokens', () {
      final b = ComponentBudget(
        allocatedTokens: 100,
        tokenizer: const ApproximateTokenizer(),
      );
      expect(b.usedTokens, 0);
      expect(b.remainingTokens, 100);
      expect(b.isOverBudget, isFalse);
    });

    test('consume counts tokens and records usage', () {
      final b = ComponentBudget(
        allocatedTokens: 100,
        tokenizer: const ApproximateTokenizer(),
      );
      final count = b.consume('abcdefgh'); // 8 chars → 2 tokens
      expect(count, 2);
      expect(b.usedTokens, 2);
      expect(b.remainingTokens, 98);
    });

    test('multiple consumes accumulate', () {
      final b = ComponentBudget(
        allocatedTokens: 100,
        tokenizer: const ApproximateTokenizer(),
      );
      b.consume('abcd'); // 1 token
      b.consume('abcdefgh'); // 2 tokens
      expect(b.usedTokens, 3);
      expect(b.remainingTokens, 97);
    });

    test('isOverBudget when exceeded', () {
      final b = ComponentBudget(
        allocatedTokens: 1,
        tokenizer: const ApproximateTokenizer(),
      );
      b.consume('abcdefghijklmnop'); // 16 chars → 4 tokens
      expect(b.isOverBudget, isTrue);
      expect(b.remainingTokens, -3);
    });

    test('isOverBudget false at exact allocation', () {
      final b = ComponentBudget(
        allocatedTokens: 2,
        tokenizer: const ApproximateTokenizer(),
      );
      b.consume('abcdefgh'); // 8 chars → 2 tokens
      expect(b.isOverBudget, isFalse);
      expect(b.remainingTokens, 0);
    });

    test('consume empty string adds 0', () {
      final b = ComponentBudget(
        allocatedTokens: 100,
        tokenizer: const ApproximateTokenizer(),
      );
      final count = b.consume('');
      expect(count, 0);
      expect(b.usedTokens, 0);
    });
  });

  // ── Budget ───────────────────────────────────────────────────────────────

  group('Budget', () {
    test('forComponent returns correct allocation', () {
      final budget = _testBudget(
        allocation: {'task': 500, 'durable': 300},
      );
      final cb = budget.forComponent('task');
      expect(cb.allocatedTokens, 500);
    });

    test('forComponent returns 0 for unknown component', () {
      final budget = _testBudget(allocation: {'task': 500});
      final cb = budget.forComponent('unknown');
      expect(cb.allocatedTokens, 0);
    });

    test('each forComponent call returns fresh ComponentBudget', () {
      final budget = _testBudget(allocation: {'task': 500});
      final a = budget.forComponent('task');
      a.consume('some text');
      final b = budget.forComponent('task');
      expect(b.usedTokens, 0); // Independent of a.
    });

    test('forComponent shares the same tokenizer', () {
      const tokenizer = ApproximateTokenizer();
      final budget = Budget(
        totalTokens: 1000,
        allocation: {'a': 500},
        tokenizer: tokenizer,
      );
      final cb = budget.forComponent('a');
      expect(identical(cb.tokenizer, tokenizer), isTrue);
    });
  });

  // ── ConsolidationReport ──────────────────────────────────────────────────

  group('ConsolidationReport', () {
    test('defaults all counters to 0', () {
      const r = ConsolidationReport(componentName: 'test');
      expect(r.itemsCreated, 0);
      expect(r.itemsMerged, 0);
      expect(r.itemsDecayed, 0);
      expect(r.episodesConsumed, 0);
    });

    test('accepts explicit counter values', () {
      const r = ConsolidationReport(
        componentName: 'test',
        itemsCreated: 3,
        itemsMerged: 2,
        itemsDecayed: 1,
        episodesConsumed: 5,
      );
      expect(r.componentName, 'test');
      expect(r.itemsCreated, 3);
      expect(r.itemsMerged, 2);
      expect(r.itemsDecayed, 1);
      expect(r.episodesConsumed, 5);
    });
  });

  // ── LabeledRecall ────────────────────────────────────────────────────────

  group('LabeledRecall', () {
    test('stores all fields', () {
      final r = LabeledRecall(
        componentName: 'task',
        content: 'some memory',
        score: 0.85,
        metadata: {'key': 'value'},
      );
      expect(r.componentName, 'task');
      expect(r.content, 'some memory');
      expect(r.score, 0.85);
      expect(r.metadata, {'key': 'value'});
    });

    test('metadata defaults to null', () {
      const r = LabeledRecall(
        componentName: 'task',
        content: 'test',
        score: 0.5,
      );
      expect(r.metadata, isNull);
    });
  });

  // ── BudgetUsage ──────────────────────────────────────────────────────────

  group('BudgetUsage', () {
    test('overBudget false when used <= allocated', () {
      const u = BudgetUsage(componentName: 'a', allocated: 100, used: 100);
      expect(u.overBudget, isFalse);
    });

    test('overBudget true when used > allocated', () {
      const u = BudgetUsage(componentName: 'a', allocated: 100, used: 101);
      expect(u.overBudget, isTrue);
    });

    test('overBudget false when used is 0', () {
      const u = BudgetUsage(componentName: 'a', allocated: 100, used: 0);
      expect(u.overBudget, isFalse);
    });
  });

  // ── WeightedMixer ────────────────────────────────────────────────────────

  group('WeightedMixer', () {
    test('empty input returns empty result', () {
      const mixer = WeightedMixer();
      final result = mixer.mix({}, _testBudget());
      expect(result.items, isEmpty);
      expect(result.componentUsage, isEmpty);
      expect(result.totalTokensUsed, 0);
    });

    test('single component single item passes through', () {
      const mixer = WeightedMixer();
      final result = mixer.mix({
        'task': [
          LabeledRecall(componentName: 'task', content: 'hello', score: 0.9),
        ],
      }, _testBudget(allocation: {'task': 500}));

      expect(result.items, hasLength(1));
      expect(result.items.first.content, 'hello');
      expect(result.totalTokensUsed, greaterThan(0));
    });

    test('multiplies scores by component weight', () {
      const mixer = WeightedMixer(weights: {'high': 2.0, 'low': 0.5});
      // 'low' has raw score 0.9 but weight 0.5 → adjusted 0.45
      // 'high' has raw score 0.5 but weight 2.0 → adjusted 1.0
      final result = mixer.mix({
        'low': [
          LabeledRecall(componentName: 'low', content: 'low item', score: 0.9),
        ],
        'high': [
          LabeledRecall(
              componentName: 'high', content: 'high item', score: 0.5),
        ],
      }, _testBudget(allocation: {'high': 500, 'low': 500}));

      expect(result.items.first.componentName, 'high');
      expect(result.items.last.componentName, 'low');
    });

    test('sorts by adjusted score descending', () {
      const mixer = WeightedMixer();
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'low', score: 0.1),
          LabeledRecall(componentName: 'a', content: 'high', score: 0.9),
          LabeledRecall(componentName: 'a', content: 'mid', score: 0.5),
        ],
      }, _testBudget(allocation: {'a': 500}));

      expect(result.items.map((i) => i.content).toList(),
          ['high', 'mid', 'low']);
    });

    test('takes items until total budget exhausted', () {
      const mixer = WeightedMixer();
      // Each 'xxxx' is 4 chars → 1 token. Budget = 2 tokens.
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'aaaa', score: 0.9),
          LabeledRecall(componentName: 'a', content: 'bbbb', score: 0.8),
          LabeledRecall(componentName: 'a', content: 'cccc', score: 0.7),
        ],
      }, _testBudget(total: 2, allocation: {'a': 10}));

      expect(result.items, hasLength(2));
      expect(result.totalTokensUsed, 2);
    });

    test('always includes at least one item even if over budget', () {
      const mixer = WeightedMixer();
      // 'long content here!!' is 19 chars → 5 tokens. Budget = 1 token.
      final result = mixer.mix({
        'a': [
          LabeledRecall(
              componentName: 'a', content: 'long content here!!', score: 0.9),
        ],
      }, _testBudget(total: 1, allocation: {'a': 1}));

      expect(result.items, hasLength(1));
      expect(result.totalTokensUsed, greaterThan(1));
    });

    test('unweighted component defaults to weight 1.0', () {
      const mixer = WeightedMixer(weights: {'a': 2.0});
      // 'b' not in weights → defaults to 1.0
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'aaaa', score: 0.5),
        ],
        'b': [
          LabeledRecall(componentName: 'b', content: 'bbbb', score: 0.5),
        ],
      }, _testBudget(allocation: {'a': 500, 'b': 500}));

      // 'a' adjusted = 0.5 * 2.0 = 1.0, 'b' adjusted = 0.5 * 1.0 = 0.5
      expect(result.items.first.componentName, 'a');
    });

    test('reports per-component budget usage', () {
      const mixer = WeightedMixer();
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'aaaa', score: 0.9),
        ],
        'b': [
          LabeledRecall(componentName: 'b', content: 'bbbb', score: 0.8),
        ],
      }, _testBudget(allocation: {'a': 100, 'b': 200}));

      expect(result.componentUsage, contains('a'));
      expect(result.componentUsage, contains('b'));
      expect(result.componentUsage['a']!.allocated, 100);
      expect(result.componentUsage['b']!.allocated, 200);
      expect(result.componentUsage['a']!.used, greaterThan(0));
      expect(result.componentUsage['b']!.used, greaterThan(0));
    });

    test('reports totalTokensUsed accurately', () {
      const mixer = WeightedMixer();
      // 'abcd' = 4 chars → 1 token each
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'abcd', score: 0.9),
          LabeledRecall(componentName: 'a', content: 'efgh', score: 0.8),
        ],
      }, _testBudget(allocation: {'a': 500}));

      expect(result.totalTokensUsed, 2);
    });

    test('over-budget component flagged in usage', () {
      const mixer = WeightedMixer();
      // Component 'a' allocated 0 tokens but has items selected.
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'abcd', score: 0.9),
        ],
      }, _testBudget(allocation: {'a': 0}));

      expect(result.componentUsage['a']!.overBudget, isTrue);
    });

    test('component with no selected items gets zero usage', () {
      const mixer = WeightedMixer();
      // Budget is 1 token. Only 'a' fits. 'b' is excluded.
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'abcd', score: 0.9),
        ],
        'b': [
          LabeledRecall(componentName: 'b', content: 'efgh', score: 0.1),
        ],
      }, _testBudget(total: 1, allocation: {'a': 100, 'b': 100}));

      expect(result.componentUsage['b']!.used, 0);
    });

    test('multiple components items interleaved by score', () {
      const mixer = WeightedMixer();
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'a1', score: 0.9),
          LabeledRecall(componentName: 'a', content: 'a2', score: 0.5),
        ],
        'b': [
          LabeledRecall(componentName: 'b', content: 'b1', score: 0.7),
          LabeledRecall(componentName: 'b', content: 'b2', score: 0.3),
        ],
      }, _testBudget(allocation: {'a': 500, 'b': 500}));

      final names = result.items.map((i) => i.content).toList();
      expect(names, ['a1', 'b1', 'a2', 'b2']);
    });
  });

  // ── InMemoryEpisodeStore ─────────────────────────────────────────────────

  group('InMemoryEpisodeStore', () {
    test('insert adds episodes', () async {
      final store = InMemoryEpisodeStore();
      await store.insert([_episode('a'), _episode('b')]);
      expect(store.length, 2);
    });

    test('fetchUnconsolidated returns all initially', () async {
      final store = InMemoryEpisodeStore();
      await store.insert([_episode('a'), _episode('b')]);
      final unconsolidated = await store.fetchUnconsolidated();
      expect(unconsolidated, hasLength(2));
    });

    test('markConsolidated excludes from fetch', () async {
      final store = InMemoryEpisodeStore();
      final ep = _episode('a');
      await store.insert([ep, _episode('b')]);
      await store.markConsolidated([ep]);
      final unconsolidated = await store.fetchUnconsolidated();
      expect(unconsolidated, hasLength(1));
      expect(unconsolidated.first.content, 'b');
    });

    test('unconsolidatedCount tracks correctly', () async {
      final store = InMemoryEpisodeStore();
      final episodes = [_episode('a'), _episode('b'), _episode('c')];
      await store.insert(episodes);
      expect(store.unconsolidatedCount, 3);
      await store.markConsolidated([episodes[0]]);
      expect(store.unconsolidatedCount, 2);
    });
  });

  // ── Engine lifecycle ─────────────────────────────────────────────────────

  group('Engine lifecycle', () {
    test('initialize calls initialize on all components', () async {
      final a = StubComponent(name: 'a');
      final b = StubComponent(name: 'b');
      final engine = _engine(components: [a, b]);
      await engine.initialize();
      expect(a.initialized, isTrue);
      expect(b.initialized, isTrue);
    });

    test('close calls close on all components', () async {
      final a = StubComponent(name: 'a');
      final b = StubComponent(name: 'b');
      final engine = _engine(components: [a, b]);
      await engine.initialize();
      await engine.close();
      expect(a.closed, isTrue);
      expect(b.closed, isTrue);
    });

    test('close flushes buffer before closing', () async {
      final store = InMemoryEpisodeStore();
      final engine = _engine(store: store);
      await engine.initialize();
      await engine.record(_episode('buffered'));
      expect(store.length, 0); // Still in buffer.
      await engine.close();
      expect(store.length, 1); // Flushed by close.
    });

    test('record before initialize throws StateError', () {
      final engine = _engine();
      expect(
        () => engine.record(_episode('test')),
        throwsStateError,
      );
    });

    test('consolidate before initialize throws StateError', () {
      final engine = _engine();
      expect(
        () => engine.consolidate(_noopLlm),
        throwsStateError,
      );
    });

    test('recall before initialize throws StateError', () {
      final engine = _engine();
      expect(
        () => engine.recall('test'),
        throwsStateError,
      );
    });
  });

  // ── Episode recording ────────────────────────────────────────────────────

  group('Episode recording', () {
    test('record adds to buffer', () async {
      final engine = _engine();
      await engine.initialize();
      await engine.record(_episode('a'));
      expect(engine.bufferSize, 1);
    });

    test('flush writes buffer to store and clears it', () async {
      final store = InMemoryEpisodeStore();
      final engine = _engine(store: store);
      await engine.initialize();
      await engine.record(_episode('a'));
      await engine.record(_episode('b'));
      await engine.flush();
      expect(engine.bufferSize, 0);
      expect(store.length, 2);
    });

    test('flush is no-op when buffer is empty', () async {
      final store = InMemoryEpisodeStore();
      final engine = _engine(store: store);
      await engine.initialize();
      await engine.flush();
      expect(store.length, 0);
    });

    test('auto-flush at threshold', () async {
      final store = InMemoryEpisodeStore();
      final engine = _engine(store: store, flushThreshold: 3);
      await engine.initialize();
      await engine.record(_episode('a'));
      await engine.record(_episode('b'));
      expect(store.length, 0); // Not yet.
      await engine.record(_episode('c'));
      expect(store.length, 3); // Flushed at threshold.
      expect(engine.bufferSize, 0);
    });

    test('manual flush before threshold', () async {
      final store = InMemoryEpisodeStore();
      final engine = _engine(store: store, flushThreshold: 100);
      await engine.initialize();
      await engine.record(_episode('a'));
      expect(store.length, 0);
      await engine.flush();
      expect(store.length, 1);
    });
  });

  // ── Parallel consolidation ───────────────────────────────────────────────

  group('Parallel consolidation', () {
    test('all components receive the same episodes', () async {
      final a = StubComponent(name: 'a');
      final b = StubComponent(name: 'b');
      final engine = _engine(
        components: [a, b],
        budget: _testBudget(allocation: {'a': 500, 'b': 500}),
      );
      await engine.initialize();
      await engine.record(_episode('ep1'));
      await engine.record(_episode('ep2'));
      await engine.flush();

      await engine.consolidate(_noopLlm);

      expect(a.lastConsolidationEpisodes, hasLength(2));
      expect(b.lastConsolidationEpisodes, hasLength(2));
      expect(
        a.lastConsolidationEpisodes!.first.id,
        b.lastConsolidationEpisodes!.first.id,
      );
    });

    test('components receive their specific budget', () async {
      final a = StubComponent(name: 'a');
      final b = StubComponent(name: 'b');
      final engine = _engine(
        components: [a, b],
        budget: _testBudget(allocation: {'a': 100, 'b': 200}),
      );
      await engine.initialize();
      await engine.record(_episode('ep1'));
      await engine.flush();

      await engine.consolidate(_noopLlm);

      expect(a.lastConsolidationBudget!.allocatedTokens, 100);
      expect(b.lastConsolidationBudget!.allocatedTokens, 200);
    });

    test('episodes marked consolidated after all components finish', () async {
      final store = InMemoryEpisodeStore();
      final a = StubComponent(name: 'a');
      final engine = _engine(components: [a], store: store);
      await engine.initialize();
      await engine.record(_episode('ep1'));
      await engine.flush();
      expect(store.unconsolidatedCount, 1);

      await engine.consolidate(_noopLlm);
      expect(store.unconsolidatedCount, 0);
    });

    test('returns reports from all components', () async {
      final a = StubComponent(
        name: 'a',
        onConsolidate: (eps) => ConsolidationReport(
          componentName: 'a',
          itemsCreated: 2,
          episodesConsumed: eps.length,
        ),
      );
      final b = StubComponent(
        name: 'b',
        onConsolidate: (eps) => ConsolidationReport(
          componentName: 'b',
          itemsMerged: 1,
        ),
      );
      final engine = _engine(
        components: [a, b],
        budget: _testBudget(allocation: {'a': 500, 'b': 500}),
      );
      await engine.initialize();
      await engine.record(_episode('ep1'));
      await engine.flush();

      final reports = await engine.consolidate(_noopLlm);

      expect(reports, hasLength(2));
      final reportA = reports.firstWhere((r) => r.componentName == 'a');
      final reportB = reports.firstWhere((r) => r.componentName == 'b');
      expect(reportA.itemsCreated, 2);
      expect(reportB.itemsMerged, 1);
    });

    test('empty unconsolidated returns empty list', () async {
      final engine = _engine(
        components: [StubComponent(name: 'a')],
      );
      await engine.initialize();
      final reports = await engine.consolidate(_noopLlm);
      expect(reports, isEmpty);
    });

    test('consolidation flushes buffer first', () async {
      final store = InMemoryEpisodeStore();
      final a = StubComponent(name: 'a');
      final engine = _engine(components: [a], store: store);
      await engine.initialize();
      await engine.record(_episode('buffered'));
      expect(store.length, 0);

      await engine.consolidate(_noopLlm);

      expect(store.length, 1);
      expect(a.consolidateCallCount, 1);
      expect(a.lastConsolidationEpisodes, hasLength(1));
    });

    test('second consolidation only gets new episodes', () async {
      final store = InMemoryEpisodeStore();
      final a = StubComponent(name: 'a');
      final engine = _engine(components: [a], store: store);
      await engine.initialize();

      await engine.record(_episode('ep1'));
      await engine.flush();
      await engine.consolidate(_noopLlm);
      expect(a.lastConsolidationEpisodes, hasLength(1));

      await engine.record(_episode('ep2'));
      await engine.flush();
      await engine.consolidate(_noopLlm);
      expect(a.lastConsolidationEpisodes, hasLength(1));
      expect(a.lastConsolidationEpisodes!.first.content, 'ep2');
    });
  });

  // ── Parallel recall ──────────────────────────────────────────────────────

  group('Parallel recall', () {
    test('all components receive the same query', () async {
      final a = StubComponent(name: 'a');
      final b = StubComponent(name: 'b');
      final engine = _engine(
        components: [a, b],
        budget: _testBudget(allocation: {'a': 500, 'b': 500}),
      );
      await engine.initialize();

      await engine.recall('test query');

      expect(a.lastRecallQuery, 'test query');
      expect(b.lastRecallQuery, 'test query');
    });

    test('components receive their specific budget', () async {
      final a = StubComponent(name: 'a');
      final b = StubComponent(name: 'b');
      final engine = _engine(
        components: [a, b],
        budget: _testBudget(allocation: {'a': 100, 'b': 200}),
      );
      await engine.initialize();

      await engine.recall('test');

      expect(a.lastRecallBudget!.allocatedTokens, 100);
      expect(b.lastRecallBudget!.allocatedTokens, 200);
    });

    test('results are passed to mixer and returned', () async {
      final a = StubComponent(
        name: 'a',
        recallItems: [
          LabeledRecall(componentName: 'a', content: 'from a', score: 0.9),
        ],
      );
      final b = StubComponent(
        name: 'b',
        recallItems: [
          LabeledRecall(componentName: 'b', content: 'from b', score: 0.8),
        ],
      );
      final engine = _engine(
        components: [a, b],
        budget: _testBudget(allocation: {'a': 500, 'b': 500}),
      );
      await engine.initialize();

      final result = await engine.recall('query');

      expect(result.items, hasLength(2));
      expect(result.items.first.content, 'from a');
      expect(result.items.last.content, 'from b');
    });

    test('recall with no components returns empty MixResult', () async {
      final engine = _engine();
      await engine.initialize();
      final result = await engine.recall('query');
      expect(result.items, isEmpty);
      expect(result.totalTokensUsed, 0);
    });
  });

  // ── Empty states ─────────────────────────────────────────────────────────

  group('Empty states', () {
    test('zero components consolidation returns empty', () async {
      final engine = _engine();
      await engine.initialize();
      await engine.record(_episode('ep'));
      await engine.flush();
      final reports = await engine.consolidate(_noopLlm);
      expect(reports, isEmpty);
    });

    test('component returns empty recalls', () async {
      final a = StubComponent(name: 'a', recallItems: []);
      final engine = _engine(
        components: [a],
        budget: _testBudget(allocation: {'a': 500}),
      );
      await engine.initialize();
      final result = await engine.recall('query');
      expect(result.items, isEmpty);
      expect(result.componentUsage['a']!.used, 0);
    });
  });

  // ── Budget accounting integration ────────────────────────────────────────

  group('Budget accounting integration', () {
    test('engine tokenizer consistent with component budget tokenizer',
        () async {
      const tokenizer = ApproximateTokenizer();
      final budget = Budget(
        totalTokens: 1000,
        allocation: {'a': 500},
        tokenizer: tokenizer,
      );
      final a = StubComponent(name: 'a');
      final engine = Souvenir(
        components: [a],
        budget: budget,
        mixer: const WeightedMixer(),
      );
      await engine.initialize();
      await engine.recall('query');

      expect(identical(a.lastRecallBudget!.tokenizer, tokenizer), isTrue);
    });

    test('mixer uses same tokenizer for budget cutoff', () {
      const tokenizer = ApproximateTokenizer();
      const mixer = WeightedMixer();
      final budget = Budget(
        totalTokens: 2,
        allocation: {'a': 10},
        tokenizer: tokenizer,
      );

      // 'abcd' = 4 chars → 1 token. Budget = 2 tokens → fits 2 items.
      final result = mixer.mix({
        'a': [
          LabeledRecall(componentName: 'a', content: 'abcd', score: 0.9),
          LabeledRecall(componentName: 'a', content: 'efgh', score: 0.8),
          LabeledRecall(componentName: 'a', content: 'ijkl', score: 0.7),
        ],
      }, budget);

      expect(result.items, hasLength(2));
      expect(result.totalTokensUsed, 2);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PHASE 2: DurableMemory + SqliteEpisodeStore
  // ══════════════════════════════════════════════════════════════════════════

  // ── StoredMemory ───────────────────────────────────────────────────────

  group('StoredMemory', () {
    test('generates ULID id when not provided', () {
      final m = StoredMemory(content: 'test fact');
      expect(m.id, isNotEmpty);
      expect(m.id.length, 26); // ULID length
    });

    test('defaults to active status', () {
      final m = StoredMemory(content: 'test');
      expect(m.status, MemoryStatus.active);
    });

    test('defaults importance to 0.5', () {
      final m = StoredMemory(content: 'test');
      expect(m.importance, 0.5);
    });

    test('defaults temporal validity fields to null', () {
      final m = StoredMemory(content: 'test');
      expect(m.validAt, isNull);
      expect(m.invalidAt, isNull);
      expect(m.supersededBy, isNull);
    });

    test('isTemporallyValid true when no bounds set', () {
      final m = StoredMemory(content: 'test');
      expect(m.isTemporallyValid, isTrue);
    });

    test('isTemporallyValid false when invalidAt is in the past', () {
      final m = StoredMemory(
        content: 'test',
        invalidAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(m.isTemporallyValid, isFalse);
    });

    test('isTemporallyValid false when validAt is in the future', () {
      final m = StoredMemory(
        content: 'test',
        validAt: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(m.isTemporallyValid, isFalse);
    });

    test('accepts all explicit fields', () {
      final now = DateTime.now().toUtc();
      final m = StoredMemory(
        id: 'custom-id',
        content: 'user prefers Dart',
        importance: 0.9,
        entityIds: ['e1', 'e2'],
        sourceEpisodeIds: ['ep1'],
        createdAt: now,
        updatedAt: now,
        accessCount: 5,
        status: MemoryStatus.superseded,
        supersededBy: 'new-id',
        validAt: now,
        invalidAt: now.add(const Duration(days: 30)),
      );
      expect(m.id, 'custom-id');
      expect(m.importance, 0.9);
      expect(m.entityIds, ['e1', 'e2']);
      expect(m.status, MemoryStatus.superseded);
      expect(m.supersededBy, 'new-id');
    });
  });

  // ── DurableMemoryStore ─────────────────────────────────────────────────

  group('DurableMemoryStore', () {
    late StanzaSqlite db;
    late DurableMemoryStore store;

    setUp(() async {
      db = StanzaSqlite.memory();
      store = DurableMemoryStore(db);
      await store.initialize();
    });

    tearDown(() async {
      await db.close();
    });

    test('initialize creates tables idempotently', () async {
      // Second call should not throw.
      await store.initialize();
      expect(await store.activeMemoryCount(), 0);
    });

    test('insertMemory and activeMemoryCount', () async {
      await store.insertMemory(StoredMemory(content: 'fact one'));
      await store.insertMemory(StoredMemory(content: 'fact two'));
      expect(await store.activeMemoryCount(), 2);
    });

    test('searchMemories returns BM25-ranked results', () async {
      await store.insertMemory(
        StoredMemory(content: 'Dart is a programming language'),
      );
      await store.insertMemory(
        StoredMemory(content: 'Flutter uses Dart for development'),
      );
      await store.insertMemory(
        StoredMemory(content: 'Python is popular for data science'),
      );

      final results = await store.searchMemories('Dart programming');
      expect(results, isNotEmpty);
      expect(results.first.memory.content, contains('Dart'));
      expect(results.first.score, greaterThan(0));
    });

    test('searchMemories excludes non-active memories', () async {
      await store.insertMemory(
        StoredMemory(content: 'old fact about Dart', status: MemoryStatus.superseded),
      );
      await store.insertMemory(
        StoredMemory(content: 'new fact about Dart'),
      );

      final results = await store.searchMemories('Dart');
      expect(results, hasLength(1));
      expect(results.first.memory.content, 'new fact about Dart');
    });

    test('updateMemory updates specified fields', () async {
      final mem = StoredMemory(content: 'original');
      await store.insertMemory(mem);

      await store.updateMemory(
        mem.id,
        content: 'updated content',
        importance: 0.9,
      );

      final found = await store.findMemoriesByIds([mem.id]);
      expect(found, hasLength(1));
      expect(found.first.content, 'updated content');
      expect(found.first.importance, 0.9);
    });

    test('findMemoriesByIds preserves order', () async {
      final m1 = StoredMemory(content: 'first');
      final m2 = StoredMemory(content: 'second');
      final m3 = StoredMemory(content: 'third');
      await store.insertMemory(m1);
      await store.insertMemory(m2);
      await store.insertMemory(m3);

      final found = await store.findMemoriesByIds([m3.id, m1.id]);
      expect(found, hasLength(2));
      expect(found[0].content, 'third');
      expect(found[1].content, 'first');
    });

    test('upsertEntity and findEntityByName', () async {
      await store.upsertEntity(id: 'e1', name: 'Dart', type: 'project');
      final entity = await store.findEntityByName('Dart');
      expect(entity, isNotNull);
      expect(entity!.id, 'e1');
      expect(entity.type, 'project');
    });

    test('findEntityByName returns null for unknown', () async {
      final entity = await store.findEntityByName('Nonexistent');
      expect(entity, isNull);
    });

    test('findEntitiesByNameMatch finds substring matches', () async {
      await store.upsertEntity(id: 'e1', name: 'Dart', type: 'project');
      await store.upsertEntity(id: 'e2', name: 'Flutter', type: 'project');

      final matches = await store.findEntitiesByNameMatch(
        'I use Dart for my projects',
      );
      expect(matches, hasLength(1));
      expect(matches.first.name, 'Dart');
    });

    test('upsertRelationship and findRelationshipsForEntity', () async {
      await store.upsertEntity(id: 'e1', name: 'Flutter', type: 'project');
      await store.upsertEntity(id: 'e2', name: 'Dart', type: 'project');
      await store.upsertRelationship(
        fromEntity: 'e1',
        toEntity: 'e2',
        relation: 'uses',
        confidence: 0.95,
      );

      final rels = await store.findRelationshipsForEntity('e1');
      expect(rels, hasLength(1));
      expect(rels.first.relation, 'uses');
      expect(rels.first.confidence, 0.95);

      // Also found from the other direction.
      final rels2 = await store.findRelationshipsForEntity('e2');
      expect(rels2, hasLength(1));
    });

    test('findMemoriesByEntityIds finds associated memories', () async {
      final mem = StoredMemory(
        content: 'Dart is great',
        entityIds: ['e1'],
      );
      await store.insertMemory(mem);
      await store.upsertEntity(id: 'e1', name: 'Dart', type: 'project');

      final found = await store.findMemoriesByEntityIds(['e1']);
      expect(found, hasLength(1));
      expect(found.first.content, 'Dart is great');
    });

    test('findMemoriesByEntityIds excludes non-active', () async {
      final mem = StoredMemory(
        content: 'old fact',
        entityIds: ['e1'],
        status: MemoryStatus.superseded,
      );
      await store.insertMemory(mem);

      final found = await store.findMemoriesByEntityIds(['e1']);
      expect(found, isEmpty);
    });

    test('updateAccessStats bumps count and timestamp', () async {
      final mem = StoredMemory(content: 'test');
      await store.insertMemory(mem);

      await store.updateAccessStats([mem.id]);
      await store.updateAccessStats([mem.id]);

      final found = await store.findMemoriesByIds([mem.id]);
      expect(found.first.accessCount, 2);
      expect(found.first.lastAccessed, isNotNull);
    });

    test('supersede marks old as superseded', () async {
      final old = StoredMemory(content: 'old fact');
      final replacement = StoredMemory(content: 'new fact');
      await store.insertMemory(old);
      await store.insertMemory(replacement);

      await store.supersede(old.id, replacement.id);

      final found = await store.findMemoriesByIds([old.id]);
      expect(found.first.status, MemoryStatus.superseded);
      expect(found.first.supersededBy, replacement.id);
      expect(await store.activeMemoryCount(), 1);
    });

    test('applyImportanceDecay decays inactive memories', () async {
      final old = StoredMemory(
        content: 'stale fact',
        importance: 1.0,
        updatedAt: DateTime.now().subtract(const Duration(days: 100)),
      );
      final recent = StoredMemory(
        content: 'fresh fact',
        importance: 1.0,
      );
      await store.insertMemory(old);
      await store.insertMemory(recent);

      final affected = await store.applyImportanceDecay(
        inactivePeriod: const Duration(days: 90),
        decayRate: 0.5,
      );

      expect(affected, 1); // Only old memory decayed.
      final found = await store.listActiveMemories();
      final oldFound = found.firstWhere((m) => m.id == old.id);
      final recentFound = found.firstWhere((m) => m.id == recent.id);
      expect(oldFound.importance, closeTo(0.5, 0.01));
      expect(recentFound.importance, 1.0);
    });

    test('embedding round-trip via BLOB', () async {
      final mem = StoredMemory(content: 'test embedding');
      await store.insertMemory(mem);

      final embedding = [0.1, 0.2, 0.3, 0.4, 0.5];
      await store.updateMemoryEmbedding(mem.id, embedding);

      final loaded = await store.loadMemoriesWithEmbeddings();
      expect(loaded, hasLength(1));
      expect(loaded.first.id, mem.id);
      for (var i = 0; i < embedding.length; i++) {
        expect(loaded.first.embedding[i], closeTo(embedding[i], 0.001));
      }
    });

    test('listActiveMemories ordered by importance desc', () async {
      await store.insertMemory(StoredMemory(content: 'low', importance: 0.2));
      await store.insertMemory(StoredMemory(content: 'high', importance: 0.9));
      await store.insertMemory(StoredMemory(content: 'mid', importance: 0.5));

      final list = await store.listActiveMemories();
      expect(list.map((m) => m.content).toList(), ['high', 'mid', 'low']);
    });
  });

  // ── DurableMemory consolidation ────────────────────────────────────────

  group('DurableMemory consolidation', () {
    late StanzaSqlite db;
    late DurableMemoryStore store;
    late DurableMemory component;

    setUp(() async {
      db = StanzaSqlite.memory();
      store = DurableMemoryStore(db);
      // BM25 scores in a tiny corpus are near zero (e.g. 0.000003), so
      // mergeThreshold must be 0.0 to trigger conflict resolution in tests.
      component = DurableMemory(
        store: store,
        config: const DurableMemoryConfig(mergeThreshold: 0.0),
      );
      await component.initialize();
    });

    tearDown(() async {
      await db.close();
    });

    ComponentBudget _budget([int tokens = 10000]) {
      return ComponentBudget(
        allocatedTokens: tokens,
        tokenizer: const ApproximateTokenizer(),
      );
    }

    Future<String> _stubLlm(Map<String, dynamic> extraction) {
      return Future.value(jsonEncode(extraction));
    }

    test('extracts facts and creates memories', () async {
      final episodes = [
        _episode('User said they prefer composition over inheritance'),
      ];

      final report = await component.consolidate(
        episodes,
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'User prefers composition over inheritance',
              'entities': [
                {'name': 'User', 'type': 'person'},
              ],
              'importance': 0.9,
              'conflict': null,
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      expect(report.componentName, 'durable');
      expect(report.itemsCreated, 1);
      expect(report.episodesConsumed, 1);
      expect(await store.activeMemoryCount(), 1);
    });

    test('creates entities during extraction', () async {
      final episodes = [_episode('Dart is a language')];

      await component.consolidate(
        episodes,
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'Dart is a programming language by Google',
              'entities': [
                {'name': 'Dart', 'type': 'project'},
                {'name': 'Google', 'type': 'concept'},
              ],
              'importance': 0.7,
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      final dart = await store.findEntityByName('Dart');
      final google = await store.findEntityByName('Google');
      expect(dart, isNotNull);
      expect(dart!.type, 'project');
      expect(google, isNotNull);
    });

    test('creates relationships', () async {
      final episodes = [_episode('Flutter uses Dart')];

      await component.consolidate(
        episodes,
        (sys, user) => _stubLlm({
          'facts': [],
          'relationships': [
            {
              'from': 'Flutter',
              'to': 'Dart',
              'relation': 'uses',
              'confidence': 0.95,
            },
          ],
        }),
        _budget(),
      );

      final flutter = await store.findEntityByName('Flutter');
      expect(flutter, isNotNull);
      final rels = await store.findRelationshipsForEntity(flutter!.id);
      expect(rels, hasLength(1));
      expect(rels.first.relation, 'uses');
    });

    test('merges on update conflict', () async {
      // First consolidation: create initial memory.
      await component.consolidate(
        [_episode('User likes Dart')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'User likes Dart',
              'entities': [],
              'importance': 0.7,
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );
      expect(await store.activeMemoryCount(), 1);

      // Second consolidation: update with refinement.
      await component.consolidate(
        [_episode('User loves Dart for its type system')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'User loves Dart for its strong type system',
              'entities': [],
              'importance': 0.8,
              'conflict': 'update',
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      // Should still be 1 memory (merged), with updated content.
      expect(await store.activeMemoryCount(), 1);
      final memories = await store.listActiveMemories();
      expect(memories.first.content, contains('type system'));
      expect(memories.first.importance, 0.8);
    });

    test('supersedes on contradiction', () async {
      // Create initial memory.
      await component.consolidate(
        [_episode('User prefers tabs')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'User prefers tabs for indentation',
              'entities': [],
              'importance': 0.8,
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      // Contradiction: user now prefers spaces.
      final report = await component.consolidate(
        [_episode('User switched to spaces')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'User prefers spaces for indentation',
              'entities': [],
              'importance': 0.8,
              'conflict': 'contradiction',
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      expect(report.itemsCreated, 1); // New memory created.
      // One active (new), one superseded (old).
      expect(await store.activeMemoryCount(), 1);
      final active = await store.listActiveMemories();
      expect(active.first.content, contains('spaces'));
    });

    test('skips duplicate with lower importance', () async {
      // Create initial memory with high importance.
      await component.consolidate(
        [_episode('User prefers Dart')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'User prefers Dart',
              'entities': [],
              'importance': 0.9,
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      // Duplicate with lower importance — should be skipped.
      final report = await component.consolidate(
        [_episode('Again: user prefers Dart')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'User prefers Dart',
              'entities': [],
              'importance': 0.5,
              'conflict': 'duplicate',
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      expect(report.itemsCreated, 0);
      expect(report.itemsMerged, 0);
      expect(await store.activeMemoryCount(), 1);
    });

    test('empty episodes returns report with only decay', () async {
      final report = await component.consolidate([], _noopLlm, _budget());
      expect(report.itemsCreated, 0);
      expect(report.episodesConsumed, 0);
    });

    test('malformed LLM response returns graceful report', () async {
      final report = await component.consolidate(
        [_episode('some episode')],
        (sys, user) async => 'not valid json at all!!!',
        _budget(),
      );

      // Should not throw — gracefully returns empty report.
      expect(report.itemsCreated, 0);
      expect(report.itemsMerged, 0);
    });

    test('extraction prompt mentions months-level durability', () async {
      String? capturedSystem;
      await component.consolidate(
        [_episode('test')],
        (sys, user) async {
          capturedSystem = sys;
          return jsonEncode({'facts': [], 'relationships': []});
        },
        _budget(),
      );

      expect(capturedSystem, contains('months from now'));
    });

    test('extraction prompt requests conflict hints', () async {
      String? capturedSystem;
      await component.consolidate(
        [_episode('test')],
        (sys, user) async {
          capturedSystem = sys;
          return jsonEncode({'facts': [], 'relationships': []});
        },
        _budget(),
      );

      expect(capturedSystem, contains('conflict'));
      expect(capturedSystem, contains('duplicate'));
      expect(capturedSystem, contains('contradiction'));
    });

    test('reuses existing entity instead of creating duplicate', () async {
      // First consolidation creates entity.
      await component.consolidate(
        [_episode('Dart stuff')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'Dart is fast',
              'entities': [
                {'name': 'Dart', 'type': 'project'},
              ],
              'importance': 0.7,
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      // Second consolidation references same entity.
      await component.consolidate(
        [_episode('More Dart stuff')],
        (sys, user) => _stubLlm({
          'facts': [
            {
              'content': 'Dart has strong typing',
              'entities': [
                {'name': 'Dart', 'type': 'project'},
              ],
              'importance': 0.6,
            },
          ],
          'relationships': [],
        }),
        _budget(),
      );

      // Verify only one entity named 'Dart' exists.
      final entities = await store.findEntitiesByNameMatch('Dart');
      expect(entities, hasLength(1));
    });
  });

  // ── DurableMemory recall ───────────────────────────────────────────────

  group('DurableMemory recall', () {
    late StanzaSqlite db;
    late DurableMemoryStore store;
    late DurableMemory component;

    setUp(() async {
      db = StanzaSqlite.memory();
      store = DurableMemoryStore(db);
      component = DurableMemory(store: store);
      await component.initialize();
    });

    tearDown(() async {
      await db.close();
    });

    ComponentBudget _budget([int tokens = 10000]) {
      return ComponentBudget(
        allocatedTokens: tokens,
        tokenizer: const ApproximateTokenizer(),
      );
    }

    Future<void> _seedMemory(String content, {
      double importance = 0.7,
      List<String> entityIds = const [],
    }) async {
      await store.insertMemory(StoredMemory(
        content: content,
        importance: importance,
        entityIds: entityIds,
      ));
    }

    test('returns matching memories via BM25', () async {
      await _seedMemory('Dart is a programming language');
      await _seedMemory('Python is popular for ML');

      final results = await component.recall('Dart programming', _budget());
      expect(results, isNotEmpty);
      expect(results.first.content, contains('Dart'));
      expect(results.first.componentName, 'durable');
      expect(results.first.score, greaterThan(0));
    });

    test('returns empty list for no matches', () async {
      await _seedMemory('Dart is great');
      final results = await component.recall(
        'quantum computing entanglement',
        _budget(),
      );
      expect(results, isEmpty);
    });

    test('recall labels items with component name', () async {
      await _seedMemory('test fact about Dart');
      final results = await component.recall('Dart', _budget());
      for (final r in results) {
        expect(r.componentName, 'durable');
      }
    });

    test('recall includes metadata with id and importance', () async {
      await _seedMemory('Dart preference', importance: 0.9);
      final results = await component.recall('Dart', _budget());
      expect(results, isNotEmpty);
      expect(results.first.metadata, isNotNull);
      expect(results.first.metadata!['importance'], 0.9);
      expect(results.first.metadata!['id'], isNotNull);
    });

    test('recall respects budget cutoff', () async {
      // Seed several memories. Each has content ~30 chars → ~8 tokens.
      for (var i = 0; i < 10; i++) {
        await _seedMemory('Dart fact number $i is important');
      }

      // Tiny budget: only ~2 items should fit.
      final results = await component.recall('Dart fact', _budget(16));
      expect(results.length, lessThanOrEqualTo(3));
    });

    test('recall deduplicates by content', () async {
      // Insert two memories with identical content (different IDs).
      await _seedMemory('Dart is a programming language');
      await _seedMemory('Dart is a programming language');

      final results = await component.recall('Dart programming', _budget());
      // BM25 may return both, but recall should deduplicate.
      final contents = results.map((r) => r.content).toSet();
      expect(contents.length, results.length);
    });

    test('entity graph expansion finds related memories', () async {
      // Create entities and relationship.
      await store.upsertEntity(id: 'e1', name: 'Flutter', type: 'project');
      await store.upsertEntity(id: 'e2', name: 'Dart', type: 'project');
      await store.upsertRelationship(
        fromEntity: 'e1',
        toEntity: 'e2',
        relation: 'uses',
        confidence: 0.9,
      );
      // Memory linked to Dart (e2) but not directly mentioning Flutter.
      await _seedMemory(
        'Strong type system is excellent',
        entityIds: ['e2'],
      );

      // Query mentions Flutter → entity match → expand to Dart → find memory.
      final results = await component.recall('Flutter', _budget());
      expect(results, isNotEmpty);
      expect(results.first.content, contains('type system'));
    });

    test('recall updates access stats', () async {
      final mem = StoredMemory(content: 'Dart is wonderful');
      await store.insertMemory(mem);

      await component.recall('Dart', _budget());

      final found = await store.findMemoriesByIds([mem.id]);
      expect(found.first.accessCount, greaterThan(0));
    });

    test('custom component name is used in recall labels', () async {
      final customComponent = DurableMemory(
        name: 'long-term',
        store: store,
      );

      await _seedMemory('Dart fact');
      final results = await customComponent.recall('Dart', _budget());
      if (results.isNotEmpty) {
        expect(results.first.componentName, 'long-term');
      }
    });
  });

  // ── SqliteEpisodeStore ─────────────────────────────────────────────────

  group('SqliteEpisodeStore', () {
    late StanzaSqlite db;
    late SqliteEpisodeStore store;

    setUp(() async {
      db = StanzaSqlite.memory();
      store = SqliteEpisodeStore(db);
      await store.initialize();
    });

    tearDown(() async {
      await db.close();
    });

    test('insert and count', () async {
      await store.insert([_episode('a'), _episode('b')]);
      expect(await store.count(), 2);
    });

    test('fetchUnconsolidated returns all initially', () async {
      await store.insert([_episode('a'), _episode('b')]);
      final unconsolidated = await store.fetchUnconsolidated();
      expect(unconsolidated, hasLength(2));
    });

    test('markConsolidated excludes from fetch', () async {
      final ep1 = _episode('a');
      final ep2 = _episode('b');
      await store.insert([ep1, ep2]);
      await store.markConsolidated([ep1]);

      final unconsolidated = await store.fetchUnconsolidated();
      expect(unconsolidated, hasLength(1));
      expect(unconsolidated.first.content, 'b');
    });

    test('unconsolidatedCount tracks correctly', () async {
      final episodes = [_episode('a'), _episode('b'), _episode('c')];
      await store.insert(episodes);
      expect(await store.unconsolidatedCount(), 3);

      await store.markConsolidated([episodes[0]]);
      expect(await store.unconsolidatedCount(), 2);
    });

    test('fetchUnconsolidated ordered by timestamp', () async {
      final early = Episode(
        sessionId: 'ses',
        type: EpisodeType.observation,
        content: 'early',
        timestamp: DateTime(2024, 1, 1),
      );
      final late_ = Episode(
        sessionId: 'ses',
        type: EpisodeType.observation,
        content: 'late',
        timestamp: DateTime(2024, 6, 1),
      );
      // Insert in reverse order.
      await store.insert([late_, early]);

      final results = await store.fetchUnconsolidated();
      expect(results.first.content, 'early');
      expect(results.last.content, 'late');
    });

    test('empty insert is no-op', () async {
      await store.insert([]);
      expect(await store.count(), 0);
    });

    test('preserves episode fields round-trip', () async {
      final ep = Episode(
        sessionId: 'ses_42',
        type: EpisodeType.userDirective,
        content: 'do the thing',
        importance: 0.95,
      );
      await store.insert([ep]);

      final results = await store.fetchUnconsolidated();
      expect(results, hasLength(1));
      expect(results.first.id, ep.id);
      expect(results.first.sessionId, 'ses_42');
      expect(results.first.type, EpisodeType.userDirective);
      expect(results.first.content, 'do the thing');
      expect(results.first.importance, 0.95);
    });
  });

  // ── Integration: DurableMemory in engine ───────────────────────────────

  group('Integration: DurableMemory in engine', () {
    late StanzaSqlite db;
    late DurableMemoryStore memStore;
    late DurableMemory durableComponent;
    late Souvenir engine;

    setUp(() async {
      db = StanzaSqlite.memory();
      memStore = DurableMemoryStore(db);
      durableComponent = DurableMemory(store: memStore);
      engine = Souvenir(
        components: [durableComponent],
        budget: Budget(
          totalTokens: 4000,
          allocation: {'durable': 4000},
          tokenizer: const ApproximateTokenizer(),
        ),
        mixer: const WeightedMixer(weights: {'durable': 1.0}),
      );
      await engine.initialize();
    });

    tearDown(() async {
      await engine.close();
      await db.close();
    });

    test('end-to-end consolidate and recall', () async {
      // Record episode.
      await engine.record(
        _episode('User said they always use Dart for backend'),
      );

      // Consolidate with stub LLM.
      final reports = await engine.consolidate(
        (sys, user) async => jsonEncode({
          'facts': [
            {
              'content': 'User uses Dart for backend development',
              'entities': [
                {'name': 'Dart', 'type': 'project'},
              ],
              'importance': 0.8,
              'conflict': null,
            },
          ],
          'relationships': [],
        }),
      );

      expect(reports, hasLength(1));
      expect(reports.first.itemsCreated, 1);

      // Recall.
      final result = await engine.recall('Dart backend');
      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('Dart'));
      expect(result.items.first.componentName, 'durable');
    });

    test('multi-component: DurableMemory alongside stub', () async {
      final stub = StubComponent(
        name: 'task',
        recallItems: [
          LabeledRecall(
            componentName: 'task',
            content: 'current task: fix bug',
            score: 0.9,
          ),
        ],
      );

      final multiEngine = Souvenir(
        components: [durableComponent, stub],
        budget: Budget(
          totalTokens: 4000,
          allocation: {'durable': 2000, 'task': 2000},
          tokenizer: const ApproximateTokenizer(),
        ),
        mixer: const WeightedMixer(weights: {'durable': 1.0, 'task': 1.0}),
      );
      await multiEngine.initialize();

      // Seed durable memory directly.
      await memStore.insertMemory(
        StoredMemory(content: 'User prefers Dart', importance: 0.8),
      );

      final result = await multiEngine.recall('Dart');
      // Should have results from both components.
      final sources = result.items.map((i) => i.componentName).toSet();
      expect(sources, contains('task'));
      // Durable may or may not match 'Dart' via BM25 — the stub always returns.
      expect(result.items, isNotEmpty);
      await multiEngine.close();
    });

    test('SqliteEpisodeStore works with engine', () async {
      final sqliteEpStore = SqliteEpisodeStore(db);
      await sqliteEpStore.initialize();

      final sqlEngine = Souvenir(
        components: [durableComponent],
        budget: Budget(
          totalTokens: 4000,
          allocation: {'durable': 4000},
          tokenizer: const ApproximateTokenizer(),
        ),
        mixer: const WeightedMixer(),
        store: sqliteEpStore,
      );
      await sqlEngine.initialize();

      await sqlEngine.record(
        _episode('User prefers functional programming'),
      );
      await sqlEngine.flush();
      expect(await sqliteEpStore.count(), 1);
      expect(await sqliteEpStore.unconsolidatedCount(), 1);

      await sqlEngine.consolidate(
        (sys, user) async => jsonEncode({
          'facts': [
            {
              'content': 'User prefers functional programming',
              'entities': [],
              'importance': 0.7,
            },
          ],
          'relationships': [],
        }),
      );

      expect(await sqliteEpStore.unconsolidatedCount(), 0);
      await sqlEngine.close();
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PHASE 3: TaskMemory
  // ══════════════════════════════════════════════════════════════════════════

  // ── TaskItem ─────────────────────────────────────────────────────────────

  group('TaskItem', () {
    test('generates ULID id when not provided', () {
      final item = TaskItem(
        content: 'test goal',
        category: TaskItemCategory.goal,
        sessionId: 'ses_01',
      );
      expect(item.id, isNotEmpty);
      expect(item.id.length, 26);
    });

    test('defaults to active status', () {
      final item = TaskItem(
        content: 'test',
        category: TaskItemCategory.context,
        sessionId: 'ses_01',
      );
      expect(item.status, TaskItemStatus.active);
    });

    test('defaults importance to 0.6', () {
      final item = TaskItem(
        content: 'test',
        category: TaskItemCategory.result,
        sessionId: 'ses_01',
      );
      expect(item.importance, 0.6);
    });

    test('isActive true when status is active and no invalidAt', () {
      final item = TaskItem(
        content: 'test',
        category: TaskItemCategory.goal,
        sessionId: 'ses_01',
      );
      expect(item.isActive, isTrue);
    });

    test('isActive false when status is expired', () {
      final item = TaskItem(
        content: 'test',
        category: TaskItemCategory.goal,
        sessionId: 'ses_01',
        status: TaskItemStatus.expired,
      );
      expect(item.isActive, isFalse);
    });

    test('isActive false when invalidAt is in the past', () {
      final item = TaskItem(
        content: 'test',
        category: TaskItemCategory.goal,
        sessionId: 'ses_01',
        invalidAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(item.isActive, isFalse);
    });

    test('accepts all explicit fields', () {
      final now = DateTime.now().toUtc();
      final item = TaskItem(
        id: 'custom-id',
        content: 'implement auth',
        category: TaskItemCategory.decision,
        importance: 0.85,
        sessionId: 'ses_42',
        sourceEpisodeIds: ['ep1', 'ep2'],
        createdAt: now,
        updatedAt: now,
        accessCount: 3,
        status: TaskItemStatus.superseded,
        invalidAt: now.add(const Duration(hours: 4)),
      );
      expect(item.id, 'custom-id');
      expect(item.category, TaskItemCategory.decision);
      expect(item.importance, 0.85);
      expect(item.sessionId, 'ses_42');
      expect(item.sourceEpisodeIds, ['ep1', 'ep2']);
      expect(item.accessCount, 3);
      expect(item.status, TaskItemStatus.superseded);
    });
  });

  // ── InMemoryTaskMemoryStore ──────────────────────────────────────────────

  group('InMemoryTaskMemoryStore', () {
    late InMemoryTaskMemoryStore store;

    setUp(() async {
      store = InMemoryTaskMemoryStore();
      await store.initialize();
    });

    TaskItem _taskItem(
      String content, {
      TaskItemCategory category = TaskItemCategory.context,
      String sessionId = 'ses_01',
      double importance = 0.6,
    }) {
      return TaskItem(
        content: content,
        category: category,
        sessionId: sessionId,
        importance: importance,
      );
    }

    test('insert adds items', () async {
      await store.insert(_taskItem('goal one'));
      await store.insert(_taskItem('goal two'));
      expect(store.length, 2);
    });

    test('activeItemsForSession filters by session and active status', () async {
      await store.insert(_taskItem('a', sessionId: 'ses_01'));
      await store.insert(_taskItem('b', sessionId: 'ses_02'));
      await store.insert(_taskItem('c', sessionId: 'ses_01'));

      final items = await store.activeItemsForSession('ses_01');
      expect(items, hasLength(2));
      expect(items.every((i) => i.sessionId == 'ses_01'), isTrue);
    });

    test('activeItemsForSession excludes expired items', () async {
      await store.insert(_taskItem('a'));
      await store.insert(_taskItem('b'));
      await store.expireItem(
        (await store.allActiveItems()).first.id,
        DateTime.now().toUtc(),
      );

      final items = await store.activeItemsForSession('ses_01');
      expect(items, hasLength(1));
    });

    test('allActiveItems returns active across sessions', () async {
      await store.insert(_taskItem('a', sessionId: 'ses_01'));
      await store.insert(_taskItem('b', sessionId: 'ses_02'));

      final items = await store.allActiveItems();
      expect(items, hasLength(2));
    });

    test('findSimilar returns items with high token overlap in same category', () async {
      await store.insert(_taskItem(
        'implement user authentication system',
        category: TaskItemCategory.goal,
      ));
      await store.insert(_taskItem(
        'completely unrelated topic about cooking',
        category: TaskItemCategory.goal,
      ));

      final similar = await store.findSimilar(
        'user authentication feature',
        TaskItemCategory.goal,
        'ses_01',
      );
      expect(similar, isNotEmpty);
      expect(similar.first.content, contains('authentication'));
    });

    test('findSimilar excludes items in different categories', () async {
      await store.insert(_taskItem(
        'implement user authentication',
        category: TaskItemCategory.goal,
      ));

      final similar = await store.findSimilar(
        'user authentication',
        TaskItemCategory.result, // Different category
        'ses_01',
      );
      expect(similar, isEmpty);
    });

    test('findSimilar excludes items from different sessions', () async {
      await store.insert(_taskItem(
        'implement user authentication',
        category: TaskItemCategory.goal,
        sessionId: 'ses_02',
      ));

      final similar = await store.findSimilar(
        'user authentication',
        TaskItemCategory.goal,
        'ses_01', // Different session
      );
      expect(similar, isEmpty);
    });

    test('findSimilar returns empty for no overlap', () async {
      await store.insert(_taskItem(
        'implement authentication',
        category: TaskItemCategory.goal,
      ));

      final similar = await store.findSimilar(
        'quantum entanglement physics',
        TaskItemCategory.goal,
        'ses_01',
      );
      expect(similar, isEmpty);
    });

    test('expireSession marks all session items as expired', () async {
      await store.insert(_taskItem('a', sessionId: 'ses_01'));
      await store.insert(_taskItem('b', sessionId: 'ses_01'));
      await store.insert(_taskItem('c', sessionId: 'ses_02'));

      final count = await store.expireSession('ses_01', DateTime.now().toUtc());
      expect(count, 2);
      expect(await store.activeItemCount('ses_01'), 0);
      expect(await store.activeItemCount('ses_02'), 1);
    });

    test('expireItem expires single item', () async {
      final item = _taskItem('target');
      await store.insert(item);
      await store.insert(_taskItem('other'));

      await store.expireItem(item.id, DateTime.now().toUtc());
      expect(store.activeCount, 1);
    });

    test('activeItemCount tracks correctly', () async {
      await store.insert(_taskItem('a'));
      await store.insert(_taskItem('b'));
      expect(await store.activeItemCount('ses_01'), 2);

      await store.expireItem(
        (await store.allActiveItems()).first.id,
        DateTime.now().toUtc(),
      );
      expect(await store.activeItemCount('ses_01'), 1);
    });

    test('updateAccessStats bumps count and timestamp', () async {
      final item = _taskItem('test');
      await store.insert(item);

      await store.updateAccessStats([item.id]);
      await store.updateAccessStats([item.id]);

      final items = await store.allActiveItems();
      expect(items.first.accessCount, 2);
      expect(items.first.lastAccessed, isNotNull);
    });

    test('update replaces content and boosts importance', () async {
      final item = _taskItem('original', importance: 0.5);
      await store.insert(item);

      await store.update(
        item.id,
        content: 'updated content',
        importance: 0.9,
      );

      final items = await store.allActiveItems();
      expect(items.first.content, 'updated content');
      expect(items.first.importance, 0.9);
    });
  });

  // ── TaskMemoryConfig ─────────────────────────────────────────────────────

  group('TaskMemoryConfig', () {
    test('defaults are sensible', () {
      const config = TaskMemoryConfig();
      expect(config.maxItemsPerSession, 50);
      expect(config.defaultImportance, 0.6);
      expect(config.mergeThreshold, 0.4);
      expect(config.recencyDecayLambda, 0.1);
      expect(config.recallTopK, 10);
    });

    test('custom values override defaults', () {
      const config = TaskMemoryConfig(
        maxItemsPerSession: 20,
        defaultImportance: 0.8,
        recallTopK: 5,
      );
      expect(config.maxItemsPerSession, 20);
      expect(config.defaultImportance, 0.8);
      expect(config.recallTopK, 5);
    });

    test('category weights cover all categories', () {
      const config = TaskMemoryConfig();
      for (final cat in TaskItemCategory.values) {
        expect(config.categoryWeights[cat], isNotNull,
            reason: 'Missing weight for $cat');
      }
      expect(config.categoryWeights[TaskItemCategory.goal],
          greaterThan(config.categoryWeights[TaskItemCategory.context]!));
    });
  });

  // ── TaskMemory consolidation ─────────────────────────────────────────────

  group('TaskMemory consolidation', () {
    late InMemoryTaskMemoryStore store;
    late TaskMemory component;

    setUp(() async {
      store = InMemoryTaskMemoryStore();
      component = TaskMemory(store: store);
      await component.initialize();
    });

    ComponentBudget _budget([int tokens = 10000]) {
      return ComponentBudget(
        allocatedTokens: tokens,
        tokenizer: const ApproximateTokenizer(),
      );
    }

    Future<String> _stubTaskLlm(Map<String, dynamic> extraction) {
      return Future.value(jsonEncode(extraction));
    }

    test('extracts items and creates task items', () async {
      final episodes = [
        _episode('User asked to implement authentication'),
      ];

      final report = await component.consolidate(
        episodes,
        (sys, user) => _stubTaskLlm({
          'items': [
            {
              'content': 'User wants to implement authentication',
              'category': 'goal',
              'importance': 0.9,
              'action': 'new',
            },
            {
              'content': 'Using JWT tokens for auth',
              'category': 'decision',
              'importance': 0.7,
              'action': 'new',
            },
          ],
        }),
        _budget(),
      );

      expect(report.componentName, 'task');
      expect(report.itemsCreated, 2);
      expect(report.episodesConsumed, 1);
      expect(store.activeCount, 2);
    });

    test('empty episodes returns empty report', () async {
      final report = await component.consolidate([], _noopLlm, _budget());
      expect(report.itemsCreated, 0);
      expect(report.episodesConsumed, 0);
    });

    test('malformed LLM response returns graceful report', () async {
      final report = await component.consolidate(
        [_episode('some episode')],
        (sys, user) async => 'not valid json!!!',
        _budget(),
      );

      expect(report.itemsCreated, 0);
      expect(report.itemsMerged, 0);
    });

    test('session boundary: new sessionId expires previous session items', () async {
      // First consolidation in session 1.
      await component.consolidate(
        [_episode('doing task A', sessionId: 'ses_01')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {
              'content': 'Working on task A',
              'category': 'goal',
              'importance': 0.8,
              'action': 'new',
            },
          ],
        }),
        _budget(),
      );
      expect(store.activeCount, 1);

      // Second consolidation in session 2 — should expire session 1 items.
      final report = await component.consolidate(
        [_episode('doing task B', sessionId: 'ses_02')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {
              'content': 'Working on task B',
              'category': 'goal',
              'importance': 0.8,
              'action': 'new',
            },
          ],
        }),
        _budget(),
      );

      expect(report.itemsDecayed, 1); // Session 1 item expired.
      expect(report.itemsCreated, 1);
      // Only session 2 item is active.
      expect(store.activeCount, 1);
      final active = await store.activeItemsForSession('ses_02');
      expect(active.first.content, 'Working on task B');
    });

    test('first consolidation sets currentSessionId', () async {
      expect(component.currentSessionId, isNull);

      await component.consolidate(
        [_episode('test', sessionId: 'ses_42')],
        (sys, user) => _stubTaskLlm({'items': []}),
        _budget(),
      );

      expect(component.currentSessionId, 'ses_42');
    });

    test('merge action updates existing item', () async {
      // Create initial item.
      await component.consolidate(
        [_episode('implement auth')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {
              'content': 'Implementing user authentication',
              'category': 'goal',
              'importance': 0.7,
              'action': 'new',
            },
          ],
        }),
        _budget(),
      );

      // Merge with refined goal.
      final report = await component.consolidate(
        [_episode('auth with JWT')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {
              'content': 'Implementing user authentication with JWT',
              'category': 'goal',
              'importance': 0.85,
              'action': 'merge',
            },
          ],
        }),
        _budget(),
      );

      expect(report.itemsMerged, 1);
      expect(report.itemsCreated, 0);
      expect(store.activeCount, 1);
      final items = await store.activeItemsForSession('ses_01');
      expect(items.first.content, contains('JWT'));
      expect(items.first.importance, 0.85);
    });

    test('merge action falls through to create when no similar item found', () async {
      await component.consolidate(
        [_episode('some context')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {
              'content': 'quantum computing research',
              'category': 'goal',
              'importance': 0.8,
              'action': 'merge',
            },
          ],
        }),
        _budget(),
      );

      // No prior items → merge can't find a match → creates new.
      expect(store.activeCount, 1);
    });

    test('maxItemsPerSession enforcement expires lowest importance', () async {
      final limitedComponent = TaskMemory(
        store: store,
        config: const TaskMemoryConfig(maxItemsPerSession: 2),
      );
      await limitedComponent.initialize();

      // Fill to capacity.
      await limitedComponent.consolidate(
        [_episode('first')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {'content': 'low priority item', 'category': 'context', 'importance': 0.3, 'action': 'new'},
            {'content': 'high priority goal', 'category': 'goal', 'importance': 0.9, 'action': 'new'},
          ],
        }),
        _budget(),
      );
      expect(store.activeCount, 2);

      // Third item should evict lowest importance.
      final report = await limitedComponent.consolidate(
        [_episode('third')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {'content': 'medium priority decision', 'category': 'decision', 'importance': 0.7, 'action': 'new'},
          ],
        }),
        _budget(),
      );

      expect(report.itemsDecayed, 1);
      expect(store.activeCount, 2);
      // Low priority item should be expired, high and medium remain.
      final active = await store.activeItemsForSession('ses_01');
      final importances = active.map((i) => i.importance).toList();
      expect(importances, everyElement(greaterThanOrEqualTo(0.7)));
    });

    test('category assignment from LLM', () async {
      await component.consolidate(
        [_episode('test')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {'content': 'item 1', 'category': 'goal', 'importance': 0.8, 'action': 'new'},
            {'content': 'item 2', 'category': 'decision', 'importance': 0.7, 'action': 'new'},
            {'content': 'item 3', 'category': 'result', 'importance': 0.5, 'action': 'new'},
            {'content': 'item 4', 'category': 'context', 'importance': 0.4, 'action': 'new'},
          ],
        }),
        _budget(),
      );

      final items = await store.activeItemsForSession('ses_01');
      final categories = items.map((i) => i.category).toSet();
      expect(categories, containsAll([
        TaskItemCategory.goal,
        TaskItemCategory.decision,
        TaskItemCategory.result,
        TaskItemCategory.context,
      ]));
    });

    test('default category is context when LLM omits it', () async {
      await component.consolidate(
        [_episode('test')],
        (sys, user) => _stubTaskLlm({
          'items': [
            {'content': 'no category specified', 'importance': 0.5, 'action': 'new'},
          ],
        }),
        _budget(),
      );

      final items = await store.activeItemsForSession('ses_01');
      expect(items.first.category, TaskItemCategory.context);
    });

    test('extraction prompt mentions current task focus', () async {
      String? capturedSystem;
      await component.consolidate(
        [_episode('test')],
        (sys, user) async {
          capturedSystem = sys;
          return jsonEncode({'items': []});
        },
        _budget(),
      );

      expect(capturedSystem, contains('RIGHT NOW'));
      expect(capturedSystem, contains('goal'));
      expect(capturedSystem, contains('decision'));
      expect(capturedSystem, contains('result'));
      expect(capturedSystem, contains('context'));
    });
  });

  // ── TaskMemory recall ────────────────────────────────────────────────────

  group('TaskMemory recall', () {
    late InMemoryTaskMemoryStore store;
    late TaskMemory component;

    setUp(() async {
      store = InMemoryTaskMemoryStore();
      component = TaskMemory(store: store);
      await component.initialize();
    });

    ComponentBudget _budget([int tokens = 10000]) {
      return ComponentBudget(
        allocatedTokens: tokens,
        tokenizer: const ApproximateTokenizer(),
      );
    }

    Future<void> _seedTaskItems(TaskMemory comp, List<Map<String, dynamic>> items) async {
      await comp.consolidate(
        [_episode('seed')],
        (sys, user) async => jsonEncode({'items': items}),
        _budget(),
      );
    }

    test('returns matching items via keyword overlap', () async {
      await _seedTaskItems(component, [
        {'content': 'Implementing Dart authentication system', 'category': 'goal', 'importance': 0.8, 'action': 'new'},
        {'content': 'Python script for data processing', 'category': 'context', 'importance': 0.5, 'action': 'new'},
      ]);

      final results = await component.recall('Dart authentication', _budget());
      expect(results, isNotEmpty);
      expect(results.first.content, contains('authentication'));
      expect(results.first.componentName, 'task');
      expect(results.first.score, greaterThan(0));
    });

    test('returns empty list when no current session', () async {
      // Don't consolidate anything — no session set.
      final results = await component.recall('anything', _budget());
      expect(results, isEmpty);
    });

    test('returns items even for loosely related queries (floor score)', () async {
      await _seedTaskItems(component, [
        {'content': 'Building the authentication module', 'category': 'goal', 'importance': 0.9, 'action': 'new'},
      ]);

      // Query with zero keyword overlap — floor score should still surface the item.
      final results = await component.recall('xyz completely different', _budget());
      expect(results, isNotEmpty);
      expect(results.first.score, greaterThan(0));
    });

    test('labels items with component name', () async {
      await _seedTaskItems(component, [
        {'content': 'test task item', 'category': 'context', 'importance': 0.5, 'action': 'new'},
      ]);

      final results = await component.recall('test task', _budget());
      for (final r in results) {
        expect(r.componentName, 'task');
      }
    });

    test('includes metadata with id, category, importance', () async {
      await _seedTaskItems(component, [
        {'content': 'goal item here', 'category': 'goal', 'importance': 0.9, 'action': 'new'},
      ]);

      final results = await component.recall('goal item', _budget());
      expect(results, isNotEmpty);
      expect(results.first.metadata, isNotNull);
      expect(results.first.metadata!['category'], 'goal');
      expect(results.first.metadata!['importance'], 0.9);
      expect(results.first.metadata!['id'], isNotNull);
    });

    test('category weight: goals rank higher than context (same keywords)', () async {
      await _seedTaskItems(component, [
        {'content': 'implement user authentication feature', 'category': 'context', 'importance': 0.8, 'action': 'new'},
        {'content': 'implement user authentication feature', 'category': 'goal', 'importance': 0.8, 'action': 'new'},
      ]);

      final results = await component.recall('authentication feature', _budget());
      expect(results.length, greaterThanOrEqualTo(2));
      // Goal should rank higher due to category weight.
      expect(results.first.metadata!['category'], 'goal');
    });

    test('budget-aware cutoff stops at budget limit', () async {
      await _seedTaskItems(component, [
        for (var i = 0; i < 10; i++)
          {'content': 'task item number $i with some extra words', 'category': 'context', 'importance': 0.5, 'action': 'new'},
      ]);

      // Tiny budget: ~2 items.
      final results = await component.recall('task item', _budget(20));
      expect(results.length, lessThanOrEqualTo(3));
    });

    test('updates access stats after recall', () async {
      await _seedTaskItems(component, [
        {'content': 'recall target item here', 'category': 'goal', 'importance': 0.8, 'action': 'new'},
      ]);

      await component.recall('recall target', _budget());

      final items = await store.activeItemsForSession('ses_01');
      expect(items.first.accessCount, greaterThan(0));
      expect(items.first.lastAccessed, isNotNull);
    });

    test('custom component name used in recall labels', () async {
      final customComponent = TaskMemory(
        name: 'working-memory',
        store: store,
      );
      await customComponent.initialize();

      await _seedTaskItems(customComponent, [
        {'content': 'custom named item', 'category': 'context', 'importance': 0.5, 'action': 'new'},
      ]);

      final results = await customComponent.recall('custom named', _budget());
      expect(results, isNotEmpty);
      expect(results.first.componentName, 'working-memory');
    });
  });

  // ── Integration: TaskMemory in engine ────────────────────────────────────

  group('Integration: TaskMemory in engine', () {
    late TaskMemory taskComponent;
    late Souvenir engine;

    setUp(() async {
      taskComponent = TaskMemory();
      engine = Souvenir(
        components: [taskComponent],
        budget: Budget(
          totalTokens: 4000,
          allocation: {'task': 4000},
          tokenizer: const ApproximateTokenizer(),
        ),
        mixer: const WeightedMixer(weights: {'task': 1.0}),
      );
      await engine.initialize();
    });

    tearDown(() async {
      await engine.close();
    });

    test('end-to-end consolidate and recall', () async {
      await engine.record(
        _episode('User wants to add dark mode to the app'),
      );

      final reports = await engine.consolidate(
        (sys, user) async => jsonEncode({
          'items': [
            {
              'content': 'Adding dark mode toggle to application',
              'category': 'goal',
              'importance': 0.85,
              'action': 'new',
            },
          ],
        }),
      );

      expect(reports, hasLength(1));
      expect(reports.first.itemsCreated, 1);

      final result = await engine.recall('dark mode');
      expect(result.items, isNotEmpty);
      expect(result.items.first.content, contains('dark mode'));
      expect(result.items.first.componentName, 'task');
    });

    test('multi-component: TaskMemory alongside DurableMemory stub', () async {
      final stub = StubComponent(
        name: 'durable',
        recallItems: [
          LabeledRecall(
            componentName: 'durable',
            content: 'User prefers Dart for backend',
            score: 0.8,
          ),
        ],
      );

      final multiEngine = Souvenir(
        components: [taskComponent, stub],
        budget: Budget(
          totalTokens: 4000,
          allocation: {'task': 2000, 'durable': 2000},
          tokenizer: const ApproximateTokenizer(),
        ),
        mixer: const WeightedMixer(weights: {'task': 1.0, 'durable': 1.0}),
      );
      await multiEngine.initialize();

      // Record and consolidate to seed task memory.
      await multiEngine.record(
        _episode('Working on Dart backend'),
      );
      await multiEngine.consolidate(
        (sys, user) async => jsonEncode({
          'items': [
            {
              'content': 'Building Dart backend API',
              'category': 'goal',
              'importance': 0.8,
              'action': 'new',
            },
          ],
        }),
      );

      final result = await multiEngine.recall('Dart backend');
      final sources = result.items.map((i) => i.componentName).toSet();
      expect(sources, contains('durable')); // From stub.
      expect(sources, contains('task'));     // From task memory.
      await multiEngine.close();
    });

    test('session boundary through engine', () async {
      // Session 1.
      await engine.record(_episode('task A', sessionId: 'ses_01'));
      await engine.consolidate(
        (sys, user) async => jsonEncode({
          'items': [
            {'content': 'Working on task A', 'category': 'goal', 'importance': 0.8, 'action': 'new'},
          ],
        }),
      );

      // Session 2 — should expire session 1 items.
      await engine.record(_episode('task B', sessionId: 'ses_02'));
      final reports = await engine.consolidate(
        (sys, user) async => jsonEncode({
          'items': [
            {'content': 'Working on task B', 'category': 'goal', 'importance': 0.8, 'action': 'new'},
          ],
        }),
      );

      expect(reports.first.itemsDecayed, 1);

      // Recall should only return session 2 items.
      final result = await engine.recall('Working on task');
      final contents = result.items.map((i) => i.content).toList();
      expect(contents.any((c) => c.contains('task B')), isTrue);
      // Task A should be expired and not returned.
      expect(contents.any((c) => c.contains('task A')), isFalse);
    });

    test('budget allocation respected', () async {
      await engine.record(_episode('test'));
      await engine.consolidate(
        (sys, user) async => jsonEncode({
          'items': [
            {'content': 'some task item', 'category': 'context', 'importance': 0.5, 'action': 'new'},
          ],
        }),
      );

      // Engine allocates 4000 tokens to 'task'.
      final result = await engine.recall('task item');
      expect(result.items, isNotEmpty);
      expect(result.totalTokensUsed, greaterThan(0));
    });

    test('empty recall before any consolidation', () async {
      final result = await engine.recall('anything');
      expect(result.items, isEmpty);
    });
  });
}
