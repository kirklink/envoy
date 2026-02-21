import 'package:ulid/ulid.dart';

/// A consolidated semantic memory (Tier 2).
///
/// Derived from one or more episodes via the consolidation pipeline.
/// Represents durable knowledge: facts, preferences, decisions.
class Memory {
  final String id;
  final String content;
  final List<String> entityIds;
  final double importance;
  final List<double>? embedding;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> sourceEpisodeIds;
  final int accessCount;
  final DateTime? lastAccessed;

  Memory({
    String? id,
    required this.content,
    this.entityIds = const [],
    this.importance = 0.5,
    this.embedding,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.sourceEpisodeIds = const [],
    this.accessCount = 0,
    this.lastAccessed,
  })  : id = id ?? Ulid().toString(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();
}
