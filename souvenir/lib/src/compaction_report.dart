/// Report of what [Souvenir.compact()] did.
///
/// Each field tracks one category of pruning action. All counts represent
/// the number of items physically deleted or merged during this compaction.
class CompactionReport {
  /// Number of expired memories physically deleted.
  final int expiredPruned;

  /// Number of superseded memories physically deleted.
  final int supersededPruned;

  /// Number of decayed memories physically deleted.
  final int decayedPruned;

  /// Number of consolidated episodes physically deleted.
  final int episodesPruned;

  /// Number of near-duplicate active memories merged (losers superseded).
  final int duplicatesMerged;

  /// Number of orphaned entities removed from the graph.
  final int entitiesRemoved;

  /// Number of orphaned relationships removed from the graph.
  final int relationshipsRemoved;

  const CompactionReport({
    this.expiredPruned = 0,
    this.supersededPruned = 0,
    this.decayedPruned = 0,
    this.episodesPruned = 0,
    this.duplicatesMerged = 0,
    this.entitiesRemoved = 0,
    this.relationshipsRemoved = 0,
  });

  /// Total memories physically deleted (expired + superseded + decayed).
  int get totalMemoriesPruned =>
      expiredPruned + supersededPruned + decayedPruned;
}
