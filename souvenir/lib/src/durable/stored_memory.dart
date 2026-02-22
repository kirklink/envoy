import 'package:ulid/ulid.dart';

/// Status of a stored durable memory.
enum MemoryStatus {
  /// Active and eligible for recall.
  active,

  /// Replaced by a newer memory (contradiction resolution).
  superseded,

  /// Explicitly invalidated (temporal validity expired).
  invalidated,
}

/// A consolidated durable memory with temporal validity.
///
/// Represents long-lived knowledge: facts, preferences, decisions.
/// Stored in the `durable_memories` SQLite table, owned by
/// [DurableMemory].
class StoredMemory {
  /// Unique identifier (ULID).
  final String id;

  /// The memory content — a standalone, self-contained statement.
  final String content;

  /// Long-term importance score (0.0–1.0).
  final double importance;

  /// IDs of entities referenced by this memory.
  final List<String> entityIds;

  /// IDs of source episodes that contributed to this memory.
  final List<String> sourceEpisodeIds;

  /// When this memory was first created.
  final DateTime createdAt;

  /// When this memory was last modified (content merge, importance update).
  final DateTime updatedAt;

  /// When this memory was last recalled.
  final DateTime? lastAccessed;

  /// Number of times this memory has been recalled.
  final int accessCount;

  /// Current lifecycle status.
  final MemoryStatus status;

  /// ID of the memory that superseded this one (when [status] is
  /// [MemoryStatus.superseded]).
  final String? supersededBy;

  /// When this memory became valid. Null means valid since [createdAt].
  final DateTime? validAt;

  /// When this memory became invalid. Null means still valid.
  final DateTime? invalidAt;

  StoredMemory({
    String? id,
    required this.content,
    this.importance = 0.5,
    this.entityIds = const [],
    this.sourceEpisodeIds = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastAccessed,
    this.accessCount = 0,
    this.status = MemoryStatus.active,
    this.supersededBy,
    this.validAt,
    this.invalidAt,
  })  : id = id ?? Ulid().toString(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  /// Whether this memory is currently valid based on temporal bounds.
  bool get isTemporallyValid {
    final now = DateTime.now().toUtc();
    if (validAt != null && now.isBefore(validAt!)) return false;
    if (invalidAt != null && now.isAfter(invalidAt!)) return false;
    return true;
  }
}
