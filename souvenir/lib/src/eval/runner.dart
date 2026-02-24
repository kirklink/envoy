import '../embedding_provider.dart';
import '../in_memory_memory_store.dart';
import '../recall.dart';
import '../tokenizer.dart';
import 'scenarios.dart';
import 'types.dart';

/// Runs [EvalScenario]s against a [RecallConfig] and collects metrics.
class EvalRunner {
  final RecallConfig config;
  final EmbeddingProvider? embeddings;
  final Tokenizer tokenizer;

  EvalRunner({
    required this.config,
    this.embeddings,
    this.tokenizer = const ApproximateTokenizer(),
  });

  /// Runs all [scenarios] and returns a [RunSummary].
  ///
  /// Each scenario gets a fresh [InMemoryMemoryStore] — scenarios are
  /// fully isolated from each other.
  Future<RunSummary> runAll(
    List<EvalScenario> scenarios, {
    String embeddingMode = 'fake',
  }) async {
    final results = <ScenarioResult>[];
    for (final scenario in scenarios) {
      results.add(await _runScenario(scenario));
    }
    return RunSummary(
      timestamp: DateTime.now().toUtc(),
      config: config,
      embeddingMode: embeddingMode,
      scenarioResults: results,
    );
  }

  Future<ScenarioResult> _runScenario(EvalScenario scenario) async {
    // Fresh isolated store for each scenario.
    final store = InMemoryMemoryStore();
    await store.initialize();

    // Use the configured provider, or fall back to the built-in fake provider
    // so that vector recall is always active (memories are embedded during
    // setup; recall needs the same provider to embed the query).
    final effectiveEmbeddings = embeddings ?? EvalEmbeddingProvider();

    // Let the scenario populate the store.
    await scenario.setup(store, effectiveEmbeddings);

    final recall = UnifiedRecall(
      store: store,
      tokenizer: tokenizer,
      config: config,
      embeddings: effectiveEmbeddings,
    );

    final queryResults = <QueryResult>[];
    for (final query in scenario.queries) {
      queryResults.add(await _runQuery(recall, query));
    }

    return ScenarioResult(scenario: scenario, queryResults: queryResults);
  }

  Future<QueryResult> _runQuery(
    UnifiedRecall recall,
    EvalQuery query,
  ) async {
    // "No match expected" queries: pass if results are empty.
    if (query.expectedTopFragment == kExpectEmpty) {
      final result = await recall.recall(query.query, budgetTokens: 10000);
      final pass = result.items.isEmpty;
      return QueryResult(
        query: query,
        pass: pass,
        rank: pass ? 0 : 1, // 0 = correct (empty), 1 = wrong (had results)
        reciprocalRank: pass ? 1.0 : 0.0,
        actual: result.items,
      );
    }

    // Normal ranked query: find rank of expected fragment.
    final result = await recall.recall(query.query, budgetTokens: 10000);
    final items = result.items;

    int rank = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i]
          .content
          .toLowerCase()
          .contains(query.expectedTopFragment.toLowerCase())) {
        rank = i + 1; // 1-based
        break;
      }
    }

    final pass = rank == 1;
    final rr = rank == 0 ? 0.0 : 1.0 / rank;

    return QueryResult(
      query: query,
      pass: pass,
      rank: rank,
      reciprocalRank: rr,
      actual: items,
    );
  }
}
