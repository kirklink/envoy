import 'package:stanza/stanza.dart';

part 'memory_entity.g.dart';

/// Stanza entity for the memories table (Tier 2 — semantic memory).
@Entity(name: 'memories')
class MemoryEntity {
  @PrimaryKey(autoIncrement: false)
  @Field(type: 'text')
  final String id;

  final String content;

  /// JSON-encoded List<String> of entity IDs.
  final String? entityIds;

  @Field(defaultValue: '0.5')
  final double importance;

  /// Reserved for vector embeddings (Phase 4). Null for now.
  final String? embedding;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// JSON-encoded List<String> of source episode IDs.
  final String? sourceIds;

  @Field(defaultValue: '0')
  final int accessCount;

  final DateTime? lastAccessed;

  const MemoryEntity({
    required this.id,
    required this.content,
    this.entityIds,
    required this.importance,
    this.embedding,
    required this.createdAt,
    required this.updatedAt,
    this.sourceIds,
    required this.accessCount,
    this.lastAccessed,
  });
}
