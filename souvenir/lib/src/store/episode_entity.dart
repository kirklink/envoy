import 'package:stanza/stanza.dart';

part 'episode_entity.g.dart';

/// Stanza entity for the episodes table (Tier 1 — episodic memory).
@Entity(name: 'episodes')
class EpisodeEntity {
  @PrimaryKey(autoIncrement: false)
  @Field(type: 'text')
  final String id;

  final String sessionId;

  final DateTime timestamp;

  /// EpisodeType enum name.
  final String type;

  final String content;

  @Field(defaultValue: '0.5')
  final double importance;

  @Field(defaultValue: '0')
  final int accessCount;

  final DateTime? lastAccessed;

  @Field(defaultValue: '0')
  final int consolidated;

  const EpisodeEntity({
    required this.id,
    required this.sessionId,
    required this.timestamp,
    required this.type,
    required this.content,
    required this.importance,
    required this.accessCount,
    this.lastAccessed,
    required this.consolidated,
  });
}
