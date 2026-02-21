/// A typed relationship between two entities.
class Relationship {
  final String fromEntityId;
  final String toEntityId;
  final String relation;
  final double confidence;
  final DateTime updatedAt;

  Relationship({
    required this.fromEntityId,
    required this.toEntityId,
    required this.relation,
    this.confidence = 1.0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();
}
