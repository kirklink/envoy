import 'task_item.dart';

/// Configuration for the [TaskMemory] component.
///
/// Tuned for session-scoped, fast-decaying task context. Parameters are
/// deliberately different from [DurableMemoryConfig] — shorter timeouts,
/// higher recency boost, category-based scoring.
class TaskMemoryConfig {
  /// Maximum active items per session. Lowest-importance items are expired
  /// when this limit is reached.
  final int maxItemsPerSession;

  /// Default importance for new items when the LLM does not specify one.
  final double defaultImportance;

  /// Jaccard similarity threshold for merging a new item with an existing
  /// one in the same category. Above this threshold, the existing item is
  /// updated with new content.
  final double mergeThreshold;

  /// Exponential recency decay factor. Score multiplier: e^(-λ × ageHours).
  /// At 0.1, a 6-hour-old item retains ~55% of its recency score.
  final double recencyDecayLambda;

  /// Maximum recall results before budget trimming.
  final int recallTopK;

  /// Per-category score multipliers for recall ranking.
  /// Goals and decisions are prioritized over results and context.
  final Map<TaskItemCategory, double> categoryWeights;

  const TaskMemoryConfig({
    this.maxItemsPerSession = 50,
    this.defaultImportance = 0.6,
    this.mergeThreshold = 0.4,
    this.recencyDecayLambda = 0.1,
    this.recallTopK = 10,
    this.categoryWeights = const {
      TaskItemCategory.goal: 1.5,
      TaskItemCategory.decision: 1.3,
      TaskItemCategory.result: 1.0,
      TaskItemCategory.context: 0.8,
    },
  });
}
