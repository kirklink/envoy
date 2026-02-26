/// Configuration for the [DurableMemory] component.
///
/// Tuned for long-lived knowledge: slower decay rates, higher inclusion bar,
/// and conservative merge thresholds compared to v1's monolithic config.
///
/// Recall-related settings (topK, RRF k, temporal decay) are now in
/// [RecallConfig] at the engine level.
class DurableMemoryConfig {
  /// BM25 score threshold for treating a new fact as "same topic" as an
  /// existing memory. Above this threshold, conflict resolution applies.
  ///
  /// Note: In the unified store, `findSimilar()` handles this internally.
  /// This field is retained for documentation but not currently used — the
  /// store's default similarity threshold governs merge detection.
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

  /// Importance floor below which a durable memory is marked as decayed.
  ///
  /// Without this, durable memories decay asymptotically toward zero but
  /// never get marked `decayed`, staying "active" with near-zero importance
  /// forever. Set to `null` to disable (preserving the old behavior).
  ///
  /// Lower than environmental's 0.1 because durable content should persist
  /// longer before being considered expired.
  final double? decayFloorThreshold;

  const DurableMemoryConfig({
    this.mergeThreshold = 0.5,
    this.defaultImportance = 0.5,
    this.defaultConfidence = 1.0,
    this.importanceDecayRate = 0.97,
    this.decayInactivePeriod = const Duration(days: 90),
    this.decayFloorThreshold = 0.05,
  });
}
