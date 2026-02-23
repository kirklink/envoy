import 'environmental_item.dart';

/// Configuration for the [EnvironmentalMemory] component.
///
/// Tuned for medium-lived environmental observations: decay over days to
/// weeks, moderate extraction bar, cross-session persistence.
class EnvironmentalMemoryConfig {
  /// Maximum active observations. Lowest-importance items are decayed
  /// when this limit is reached.
  final int maxItems;

  /// Default importance for new items when the LLM does not specify one.
  final double defaultImportance;

  /// Jaccard similarity threshold for merging a new observation with an
  /// existing one in the same category.
  final double mergeThreshold;

  /// Exponential recency decay factor for recall scoring (days scale).
  /// Score multiplier: e^(-λ × ageDays).
  /// At 0.03: 7 days = ~81%, 14 days = ~66%, 30 days = ~41%.
  final double recencyDecayLambda;

  /// Maximum recall results before budget trimming.
  final int recallTopK;

  /// Per-category score multipliers for recall ranking.
  /// Capabilities and constraints are prioritized — they directly inform
  /// the agent's decision-making about what it can/cannot do.
  final Map<EnvironmentalCategory, double> categoryWeights;

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
    this.maxItems = 100,
    this.defaultImportance = 0.6,
    this.mergeThreshold = 0.4,
    this.recencyDecayLambda = 0.03,
    this.recallTopK = 10,
    this.categoryWeights = const {
      EnvironmentalCategory.capability: 1.3,
      EnvironmentalCategory.constraint: 1.3,
      EnvironmentalCategory.environment: 1.0,
      EnvironmentalCategory.pattern: 0.9,
    },
    this.importanceDecayRate = 0.95,
    this.decayInactivePeriod = const Duration(days: 14),
    this.decayFloorThreshold = 0.1,
  });
}
