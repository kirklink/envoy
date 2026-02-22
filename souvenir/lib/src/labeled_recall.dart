/// A recall item labeled with its source component.
///
/// Components return these from [MemoryComponent.recall]. The [score] is
/// component-local — scores are NOT comparable across components. The
/// [Mixer]'s job is to rebalance these into a unified ranking.
class LabeledRecall {
  /// Name of the component that produced this recall.
  final String componentName;

  /// The recalled content.
  final String content;

  /// Component-local relevance score.
  ///
  /// Each component defines its own scoring scale. A score of 0.9 from
  /// one component means something different than 0.9 from another.
  final double score;

  /// Optional component-specific metadata.
  final Map<String, dynamic>? metadata;

  const LabeledRecall({
    required this.componentName,
    required this.content,
    required this.score,
    this.metadata,
  });
}
