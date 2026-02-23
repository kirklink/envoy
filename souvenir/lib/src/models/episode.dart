import 'package:ulid/ulid.dart';

/// Type of episodic event.
enum EpisodeType {
  conversation,
  observation,
  toolResult,
  error,
  decision,
  userDirective;
}

/// A raw, timestamped event in episodic memory (Tier 1).
///
/// Append-only. Source material for consolidation into semantic memory.
class Episode {
  final String id;
  final String sessionId;
  final DateTime timestamp;
  final EpisodeType type;
  final String content;
  final double importance;
  final int accessCount;
  final DateTime? lastAccessed;
  final bool consolidated;

  /// Creates an episode.
  ///
  /// When [importance] is null, built-in defaults are used.
  Episode({
    String? id,
    required this.sessionId,
    DateTime? timestamp,
    required this.type,
    required this.content,
    double? importance,
    this.accessCount = 0,
    this.lastAccessed,
    this.consolidated = false,
  })  : id = id ?? Ulid().toString(),
        timestamp = timestamp ?? DateTime.now(),
        importance = importance ?? _builtInImportance(type);

  /// Built-in fallback importance (matches original enum values).
  static double _builtInImportance(EpisodeType type) {
    return switch (type) {
      EpisodeType.userDirective => 0.95,
      EpisodeType.error => 0.8,
      EpisodeType.toolResult => 0.8,
      EpisodeType.decision => 0.75,
      EpisodeType.conversation => 0.4,
      EpisodeType.observation => 0.3,
    };
  }
}
