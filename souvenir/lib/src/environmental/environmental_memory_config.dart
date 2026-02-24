/// Configuration for the [EnvironmentalMemory] component.
///
/// Consolidation-only settings: decay rates, merge thresholds.
/// Recall is handled by the engine's unified [RecallConfig].
class EnvironmentalMemoryConfig {
  /// Default importance for new items when the LLM does not specify one.
  final double defaultImportance;

  /// Similarity threshold for merging a new observation with an existing
  /// one in the same category.
  final double mergeThreshold;

  /// Importance decay multiplier applied during consolidation to
  /// observations not accessed within [decayInactivePeriod].
  final double importanceDecayRate;

  /// Observations not accessed within this period have their importance
  /// decayed. 14 days — environmental context has a medium shelf life.
  final Duration decayInactivePeriod;

  /// Importance threshold below which items are marked as decayed and
  /// excluded from recall.
  final double decayFloorThreshold;

  const EnvironmentalMemoryConfig({
    this.defaultImportance = 0.6,
    this.mergeThreshold = 0.4,
    this.importanceDecayRate = 0.95,
    this.decayInactivePeriod = const Duration(days: 14),
    this.decayFloorThreshold = 0.1,
  });
}
