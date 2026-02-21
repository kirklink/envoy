import 'package:stanza/stanza.dart';

part 'memory_entity.g.dart';

/// Persisted record of a single agent memory entry.
///
/// Written by [EnvoyAgent.reflect] after a session completes.
/// The [type] is a free-form label chosen by the agent.
@Entity(name: 'envoy_memory')
class MemoryEntity {
  @PrimaryKey(autoIncrement: true)
  final int id;

  /// Agent-chosen category label (e.g. 'success', 'failure', 'curiosity').
  final String type;

  /// The memory content, in the agent's own words.
  final String content;

  @Field(defaultValue: 'now()')
  final DateTime createdAt;

  const MemoryEntity({
    required this.id,
    required this.type,
    required this.content,
    required this.createdAt,
  });
}
