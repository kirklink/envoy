/// Source tier of a recall result.
enum RecallSource { episodic, semantic, entity, vector }

/// A retrieved memory result with relevance score.
class Recall {
  final String id;
  final String content;
  final double score;
  final RecallSource source;
  final DateTime timestamp;
  final double importance;

  const Recall({
    required this.id,
    required this.content,
    required this.score,
    required this.source,
    required this.timestamp,
    required this.importance,
  });
}

/// Options for controlling recall queries.
class RecallOptions {
  /// Maximum number of results to return.
  final int topK;

  /// Scope episodic search to a specific session.
  final String? sessionId;

  /// Cap results by estimated token count (chars / [SouvenirConfig.tokenEstimationDivisor]).
  final int? tokenBudget;

  /// Include episodic memory in the search.
  final bool includeEpisodic;

  /// Include semantic memory in the search.
  final bool includeSemantic;

  /// Filter out results with importance below this threshold.
  final double? minImportance;

  const RecallOptions({
    this.topK = 10,
    this.sessionId,
    this.tokenBudget,
    this.includeEpisodic = true,
    this.includeSemantic = true,
    this.minImportance,
  });
}
