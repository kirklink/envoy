/// Configuration for the [TaskMemory] component.
///
/// Consolidation-only settings. Recall is handled by the engine's
/// unified [RecallConfig].
class TaskMemoryConfig {
  /// Maximum active items per session. Lowest-importance items are expired
  /// when this limit is reached.
  final int maxItemsPerSession;

  /// Default importance for new items when the LLM does not specify one.
  final double defaultImportance;

  /// Similarity threshold for merging a new item with an existing one in
  /// the same category. Above this threshold, the existing item is updated
  /// with new content.
  final double mergeThreshold;

  const TaskMemoryConfig({
    this.maxItemsPerSession = 50,
    this.defaultImportance = 0.6,
    this.mergeThreshold = 0.4,
  });
}
