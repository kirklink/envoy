/// Configuration for the [DurableMemory] component.
///
/// Tuned for long-lived knowledge: slower decay rates, higher inclusion bar,
/// and conservative merge thresholds compared to v1's monolithic config.
class DurableMemoryConfig {
  /// BM25 score threshold for treating a new fact as "same topic" as an
  /// existing memory. Above this threshold, conflict resolution applies.
  final double mergeThreshold;

  /// Fallback importance when the LLM does not specify one.
  final double defaultImportance;

  /// Fallback relationship confidence when the LLM does not specify one.
  final double defaultConfidence;

  /// Decay multiplier applied to memories not accessed within
  /// [decayInactivePeriod]. Slower than v1 (0.97 vs 0.95) because
  /// durable content should persist longer.
  final double importanceDecayRate;

  /// Memories not accessed within this period have their importance decayed.
  /// 90 days (vs v1's 30) — durable content has a longer shelf life.
  final Duration decayInactivePeriod;

  /// Lambda for temporal decay in recall scoring:
  /// `score * e^(-lambda * age_days)`.
  /// Lower than v1 (0.005 vs 0.01) — durable memories lose relevance
  /// more slowly.
  final double temporalDecayLambda;

  /// Reciprocal Rank Fusion constant (k). Same as v1.
  final int rrfK;

  /// Maximum number of recall results before budget trimming.
  final int recallTopK;

  /// Number of vector similarity candidates to consider before RRF fusion.
  final int embeddingTopK;

  const DurableMemoryConfig({
    this.mergeThreshold = 0.5,
    this.defaultImportance = 0.5,
    this.defaultConfidence = 1.0,
    this.importanceDecayRate = 0.97,
    this.decayInactivePeriod = const Duration(days: 90),
    this.temporalDecayLambda = 0.005,
    this.rrfK = 60,
    this.recallTopK = 10,
    this.embeddingTopK = 20,
  });
}
