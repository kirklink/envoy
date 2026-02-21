import 'package:ulid/ulid.dart';

/// Type classification for extracted entities.
enum EntityType {
  person,
  project,
  concept,
  preference,
  fact,
}

/// A named entity extracted from episodic memory.
class Entity {
  final String id;
  final String name;
  final EntityType type;

  Entity({
    String? id,
    required this.name,
    required this.type,
  }) : id = id ?? Ulid().toString();
}
