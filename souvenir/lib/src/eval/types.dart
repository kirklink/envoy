import '../embedding_provider.dart';
import '../memory_store.dart';
import '../recall.dart';

/// A single recall query within an [EvalScenario].
class EvalQuery {
  /// The query string passed to recall.
  final String query;

  /// Substring expected to appear in the #1 ranked result's content.
  final String expectedTopFragment;

  /// Human-readable description of what this query tests.
  final String description;

  const EvalQuery({
    required this.query,
    required this.expectedTopFragment,
    required this.description,
  });
}

/// A named evaluation scenario: a set of seed data + queries.
class EvalScenario {
  /// Short identifier used in the results table (e.g. `semantic_bridge`).
  final String name;

  /// Human-readable description shown in the markdown report.
  final String description;

  /// Seeds the memory store before queries are run.
  ///
  /// [store] is a freshly initialised [MemoryStore].
  /// [embeddings] is the active embedding provider (null if none configured).
  final Future<void> Function(MemoryStore store, EmbeddingProvider? embeddings)
      setup;

  /// Queries to run against the seeded store.
  final List<EvalQuery> queries;

  const EvalScenario({
    required this.name,
    required this.description,
    required this.setup,
    required this.queries,
  });
}

/// Result for a single [EvalQuery] within a scenario run.
class QueryResult {
  final EvalQuery query;

  /// Whether [expectedTopFragment] was found at rank 1.
  final bool pass;

  /// 1-based rank of the first result containing [expectedTopFragment].
  /// 0 means not found in the result set.
  final int rank;

  /// `1 / rank`, or 0.0 if not found.
  final double reciprocalRank;

  /// Full ranked list returned by recall, including score breakdowns.
  final List<ScoredRecall> actual;

  const QueryResult({
    required this.query,
    required this.pass,
    required this.rank,
    required this.reciprocalRank,
    required this.actual,
  });
}

/// Aggregated results for one [EvalScenario].
class ScenarioResult {
  final EvalScenario scenario;
  final List<QueryResult> queryResults;

  const ScenarioResult({
    required this.scenario,
    required this.queryResults,
  });

  int get totalQueries => queryResults.length;
  int get passedQueries => queryResults.where((r) => r.pass).length;

  /// Fraction of queries that passed.
  double get passRate =>
      totalQueries == 0 ? 0 : passedQueries / totalQueries;

  /// Mean Reciprocal Rank across all queries.
  double get mrr {
    if (queryResults.isEmpty) return 0;
    final sum =
        queryResults.fold<double>(0, (s, r) => s + r.reciprocalRank);
    return sum / queryResults.length;
  }
}

/// Summary of a complete evaluation run (all scenarios).
class RunSummary {
  final DateTime timestamp;
  final RecallConfig config;

  /// `"fake"` or `"ollama:<model>"`.
  final String embeddingMode;

  final List<ScenarioResult> scenarioResults;

  const RunSummary({
    required this.timestamp,
    required this.config,
    required this.embeddingMode,
    required this.scenarioResults,
  });

  int get totalQueries =>
      scenarioResults.fold(0, (s, r) => s + r.totalQueries);

  int get passedQueries =>
      scenarioResults.fold(0, (s, r) => s + r.passedQueries);

  double get overallPassRate =>
      totalQueries == 0 ? 0 : passedQueries / totalQueries;

  double get overallMrr {
    if (scenarioResults.isEmpty) return 0;
    final totalRR = scenarioResults.fold<double>(
      0,
      (s, r) => s + r.queryResults.fold<double>(0, (qs, qr) => qs + qr.reciprocalRank),
    );
    return totalRR / totalQueries;
  }
}

/// Delta between two [RunSummary]s, used to show improvement/regression.
class RunDelta {
  final RunSummary previous;
  final RunSummary current;

  const RunDelta({required this.previous, required this.current});

  double get mrrDelta => current.overallMrr - previous.overallMrr;
  double get passRateDelta => current.overallPassRate - previous.overallPassRate;

  /// Per-scenario MRR deltas, keyed by scenario name.
  Map<String, double> get scenarioMrrDeltas {
    final result = <String, double>{};
    for (final cur in current.scenarioResults) {
      final prev = previous.scenarioResults
          .where((r) => r.scenario.name == cur.scenario.name)
          .firstOrNull;
      if (prev != null) {
        result[cur.scenario.name] = cur.mrr - prev.mrr;
      }
    }
    return result;
  }

  /// Per-scenario pass-count deltas, keyed by scenario name.
  Map<String, int> get scenarioPassDeltas {
    final result = <String, int>{};
    for (final cur in current.scenarioResults) {
      final prev = previous.scenarioResults
          .where((r) => r.scenario.name == cur.scenario.name)
          .firstOrNull;
      if (prev != null) {
        result[cur.scenario.name] = cur.passedQueries - prev.passedQueries;
      }
    }
    return result;
  }
}
