import 'recall.dart';

/// Query intent classes recognized by [QueryClassifier] implementations.
enum QueryIntent {
  /// "What am I working on / what's the current goal" — session work.
  taskStatus,

  /// "What does the user like / what is true about X" — long-lived facts.
  factLookup,

  /// "Can I do X here / what's installed" — environment and capabilities.
  capability,

  /// No clear intent signal — recall with the base configuration.
  general,
}

/// Classifies a query and derives a per-call [RecallConfig] biased toward
/// the query's intent.
///
/// Implementations range from keyword heuristics
/// ([HeuristicQueryClassifier]) to LLM-backed classifiers. Wire one into
/// the engine (`Souvenir(queryClassifier: ...)`) for automatic adaptive
/// recall, or call [profileFor] manually and pass the result as the
/// per-call `config:` override.
abstract class QueryClassifier {
  /// Classifies [query] into an intent.
  QueryIntent classify(String query);

  /// Returns [base] adjusted for the query's intent.
  RecallConfig profileFor(String query, RecallConfig base) {
    return RecallProfiles.forIntent(classify(query), base);
  }
}

/// Named component-weight profiles, each derived from a base config.
///
/// Profiles only touch [RecallConfig.componentWeights] — thresholds,
/// signal weights, and the noise floor stay as calibrated on the base.
/// Weights multiply any existing component weights on the base so a
/// site-specific bias (e.g. durable 1.2) survives profile application.
class RecallProfiles {
  static const _taskFocus = {'task': 1.5, 'durable': 0.8, 'environmental': 0.8};
  static const _durableFocus = {
    'durable': 1.5,
    'task': 0.8,
    'environmental': 0.8,
  };
  static const _environmentFocus = {
    'environmental': 1.5,
    'task': 0.8,
    'durable': 0.8,
  };

  /// Biases recall toward session/task memories.
  static RecallConfig taskFocus(RecallConfig base) =>
      _apply(base, _taskFocus);

  /// Biases recall toward durable facts and preferences.
  static RecallConfig durableFocus(RecallConfig base) =>
      _apply(base, _durableFocus);

  /// Biases recall toward environment/capability observations.
  static RecallConfig environmentFocus(RecallConfig base) =>
      _apply(base, _environmentFocus);

  /// Returns the profile for [intent] applied to [base].
  static RecallConfig forIntent(QueryIntent intent, RecallConfig base) {
    switch (intent) {
      case QueryIntent.taskStatus:
        return taskFocus(base);
      case QueryIntent.factLookup:
        return durableFocus(base);
      case QueryIntent.capability:
        return environmentFocus(base);
      case QueryIntent.general:
        return base;
    }
  }

  static RecallConfig _apply(RecallConfig base, Map<String, double> profile) {
    final merged = Map<String, double>.of(base.componentWeights);
    for (final entry in profile.entries) {
      merged[entry.key] = (merged[entry.key] ?? 1.0) * entry.value;
    }
    return base.copyWith(componentWeights: merged);
  }
}

/// Keyword-heuristic [QueryClassifier].
///
/// Fast, deterministic, LLM-free. Matches whole words (and a few
/// phrases) against per-intent keyword sets; the intent with the most
/// hits wins, ties and zero hits fall back to [QueryIntent.general].
class HeuristicQueryClassifier extends QueryClassifier {
  static const _taskSignals = {
    'task', 'tasks', 'goal', 'goals', 'working', 'progress', 'todo',
    'next', 'plan', 'current', 'currently', 'building', 'implementing',
    'doing', 'finish', 'finished', 'blocked', 'decision', 'decided',
  };

  static const _factSignals = {
    'prefer', 'prefers', 'preferred', 'preference', 'favourite', 'favorite',
    'like', 'likes', 'love', 'loves', 'who', 'know', 'knows', 'remember',
    'fact', 'true', 'always', 'never', 'user',
  };

  static const _capabilitySignals = {
    'can', 'able', 'capability', 'capabilities', 'environment', 'installed',
    'available', 'version', 'system', 'platform', 'os', 'hardware',
    'memory', 'disk', 'supports', 'supported', 'configured', 'setup',
  };

  @override
  QueryIntent classify(String query) {
    final words = query
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toSet();

    final scores = <QueryIntent, int>{
      QueryIntent.taskStatus: words.intersection(_taskSignals).length,
      QueryIntent.factLookup: words.intersection(_factSignals).length,
      QueryIntent.capability: words.intersection(_capabilitySignals).length,
    };

    QueryIntent best = QueryIntent.general;
    var bestScore = 0;
    var tied = false;
    for (final entry in scores.entries) {
      if (entry.value > bestScore) {
        best = entry.key;
        bestScore = entry.value;
        tied = false;
      } else if (entry.value == bestScore && bestScore > 0) {
        tied = true;
      }
    }

    return (bestScore == 0 || tied) ? QueryIntent.general : best;
  }
}
