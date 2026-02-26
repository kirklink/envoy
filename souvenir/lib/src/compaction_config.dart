/// Configuration for store compaction.
///
/// Controls retention periods for tombstoned memories, consolidated episodes,
/// and the similarity threshold for near-duplicate detection.
///
/// Used by [Souvenir.compact()] to determine what to prune.
class CompactionConfig {
  /// How long to retain expired memories before physical deletion.
  final Duration expiredRetention;

  /// How long to retain superseded memories before physical deletion.
  final Duration supersededRetention;

  /// How long to retain decayed memories before physical deletion.
  final Duration decayedRetention;

  /// How long to retain consolidated episodes before physical deletion.
  final Duration episodeRetention;

  /// Cosine similarity threshold for near-duplicate detection.
  ///
  /// Active memory pairs with similarity above this threshold are merged:
  /// the higher-scored memory survives, the lower-scored one is superseded.
  /// Set to null to disable near-duplicate compaction.
  /// Requires an [EmbeddingProvider] on the engine.
  final double? deduplicationThreshold;

  const CompactionConfig({
    this.expiredRetention = const Duration(days: 7),
    this.supersededRetention = const Duration(days: 30),
    this.decayedRetention = const Duration(days: 14),
    this.episodeRetention = const Duration(days: 30),
    this.deduplicationThreshold = 0.92,
  });
}
