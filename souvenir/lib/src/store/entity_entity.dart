import 'package:stanza/stanza.dart';

part 'entity_entity.g.dart';

/// Stanza entity for the entities table (knowledge graph nodes).
///
/// Named `EntityRecord` to avoid collision with Stanza's `@Entity` annotation.
@Entity(name: 'entities')
class EntityRecord {
  @PrimaryKey(autoIncrement: false)
  @Field(type: 'text')
  final String id;

  final String name;

  /// EntityType enum name.
  final String type;

  const EntityRecord({
    required this.id,
    required this.name,
    required this.type,
  });
}
