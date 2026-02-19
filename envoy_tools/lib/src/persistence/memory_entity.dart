import 'package:stanza/annotations.dart';

part 'memory_entity.g.dart';

/// Persisted record of a single agent memory entry.
///
/// Written by [EnvoyAgent.reflect] after a session completes.
/// The [type] is a free-form label chosen by the agent.
@StanzaEntity(name: 'envoy_memory', snakeCase: true)
class MemoryEntity {
  @StanzaField(readOnly: true)
  late int id;

  /// Agent-chosen category label (e.g. 'success', 'failure', 'curiosity').
  late String type;

  /// The memory content, in the agent's own words.
  late String content;

  late DateTime createdAt;

  MemoryEntity();

  static final _$MemoryEntityTable $table = _$MemoryEntityTable();
}
