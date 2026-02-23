import 'package:ulid/ulid.dart';

/// Category of an environmental observation.
///
/// Classifies the agent's self-reflective observations about its
/// operating environment. Used for recall prioritization and
/// category-scoped merge during consolidation.
enum EnvironmentalCategory {
  /// What the agent can do: tools, APIs, file access, runtime features.
  capability,

  /// Limitations observed: rate limits, access restrictions, permission
  /// boundaries, things that failed or were unavailable.
  constraint,

  /// System/runtime context: OS, project structure, available services,
  /// directory layout, installed packages, infrastructure.
  environment,

  /// Behavioral patterns noticed: user communication style, workflow
  /// habits, system response patterns, agent's own tendencies.
  pattern,
}

/// Lifecycle status of an environmental observation.
enum EnvironmentalItemStatus {
  /// Active and eligible for recall.
  active,

  /// Decayed below importance floor — no longer relevant.
  decayed,

  /// Replaced by a newer observation during merge.
  superseded,
}

/// A single environmental observation.
///
/// Represents the agent's self-reflective awareness of its operating
/// environment. Cross-session (no sessionId), decay-driven (no invalidAt).
class EnvironmentalItem {
  /// Unique identifier (ULID).
  final String id;

  /// The observation content — a standalone statement.
  final String content;

  /// Classification for scoring and merge behavior.
  final EnvironmentalCategory category;

  /// Importance score (0.0–1.0). Decays over time via consolidation.
  final double importance;

  /// IDs of source episodes that contributed to this observation.
  final List<String> sourceEpisodeIds;

  /// When this observation was first made.
  final DateTime createdAt;

  /// When this observation was last modified (merge or decay).
  final DateTime updatedAt;

  /// When this observation was last recalled.
  DateTime? lastAccessed;

  /// Number of times this observation has been recalled.
  int accessCount;

  /// Current lifecycle status.
  EnvironmentalItemStatus status;

  EnvironmentalItem({
    String? id,
    required this.content,
    required this.category,
    this.importance = 0.6,
    this.sourceEpisodeIds = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastAccessed,
    this.accessCount = 0,
    this.status = EnvironmentalItemStatus.active,
  })  : id = id ?? Ulid().toString(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  /// Whether this observation is currently active.
  bool get isActive => status == EnvironmentalItemStatus.active;
}
