import 'package:souvenir/souvenir.dart';
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
}
