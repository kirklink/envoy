import 'package:stanza/stanza.dart';

part 'relationship_entity.g.dart';

/// Stanza entity for the relationships table (knowledge graph edges).
///
/// The real composite PK `(from_entity, to_entity, relation)` is enforced in
/// raw DDL. The [PrimaryKey] annotation on [fromEntity] satisfies the code
/// generator's single-PK requirement.
@Entity(name: 'relationships')
class RelationshipRecord {
  @PrimaryKey(autoIncrement: false)
  @Field(type: 'text')
  final String fromEntity;

  final String toEntity;

  final String relation;

  @Field(defaultValue: '1.0')
  final double confidence;

  final DateTime updatedAt;

  const RelationshipRecord({
    required this.fromEntity,
    required this.toEntity,
    required this.relation,
    required this.confidence,
    required this.updatedAt,
  });
}
