import 'package:ulid/ulid.dart';

import '../config.dart';

/// Type of episodic event.
///
/// Default importance values are configured via [SouvenirConfig] and applied
/// when an [Episode] is created without an explicit importance value.
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
  /// When [importance] is null, the default importance for the episode's [type]
  /// is resolved from [config]. If [config] is also null, built-in defaults
  /// matching the original heuristics are used.
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
    SouvenirConfig? config,
  })  : id = id ?? Ulid().toString(),
        timestamp = timestamp ?? DateTime.now(),
        importance = importance ??
            (config?.importanceForEpisodeType(type.name) ??
                _builtInImportance(type));

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
