import 'package:ulid/ulid.dart';

/// Category of a task memory item.
///
/// Used for recall prioritization (goals rank higher) and category-scoped
/// merge during consolidation (items only merge within the same category).
enum TaskItemCategory {
  /// What the user is trying to accomplish.
  goal,

  /// A choice made during the task (approach, parameter, tool).
  decision,

  /// An outcome from a tool call, computation, or action.
  result,

  /// Background information relevant to the current task.
  context,
}

/// Lifecycle status of a task memory item.
enum TaskItemStatus {
  /// Active and eligible for recall.
  active,

  /// Expired due to session boundary or capacity limit.
  expired,

  /// Replaced by a newer item during merge.
  superseded,
}

/// A single item in task memory.
///
/// Lighter than [StoredMemory]: no entity IDs, no supersededBy chain, no
/// embedding vector. Adds [category] for recall prioritization and
/// category-scoped merge.
class TaskItem {
  /// Unique identifier (ULID).
  final String id;

  /// The item content — a standalone statement.
  final String content;

  /// Classification for scoring and merge behavior.
  final TaskItemCategory category;

  /// Importance score (0.0–1.0).
  final double importance;

  /// Session that produced this item.
  final String sessionId;

  /// IDs of source episodes that contributed to this item.
  final List<String> sourceEpisodeIds;

  /// When this item was created.
  final DateTime createdAt;

  /// When this item was last modified (merge).
  final DateTime updatedAt;

  /// When this item was last recalled.
  DateTime? lastAccessed;

  /// Number of times this item has been recalled.
  int accessCount;

  /// Current lifecycle status.
  TaskItemStatus status;

  /// When this item becomes invalid (set at session boundary or capacity eviction).
  DateTime? invalidAt;

  TaskItem({
    String? id,
    required this.content,
    required this.category,
    this.importance = 0.6,
    required this.sessionId,
    this.sourceEpisodeIds = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastAccessed,
    this.accessCount = 0,
    this.status = TaskItemStatus.active,
    this.invalidAt,
  })  : id = id ?? Ulid().toString(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  /// Whether this item is currently valid based on status and temporal bounds.
  bool get isActive {
    if (status != TaskItemStatus.active) return false;
    if (invalidAt != null && DateTime.now().toUtc().isAfter(invalidAt!)) {
      return false;
    }
    return true;
  }
}
