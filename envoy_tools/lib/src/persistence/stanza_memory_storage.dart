import 'package:envoy/envoy.dart';
import 'package:stanza/stanza.dart';

import 'memory_entity.dart';

/// Stanza-backed implementation of [AgentMemory].
///
/// Persists agent self-memory entries to the `envoy_memory` table.
/// Entries are written by [EnvoyAgent.reflect] after each session.
///
/// ## Setup
///
/// ```dart
/// final memory = StanzaMemoryStorage(Stanza.url('postgresql://...'));
/// await memory.initialize();
///
/// final agent = EnvoyAgent(config, memory: memory, ...);
///
/// final response = await agent.run(task);
/// await agent.reflect();  // agent decides what to remember
///
/// // Inspect what was stored:
/// final entries = await memory.recall();
/// for (final e in entries) print('[${e.type}] ${e.content}');
/// ```
class StanzaMemoryStorage implements AgentMemory {
  final Stanza _stanza;

  StanzaMemoryStorage(this._stanza);

  /// Creates the `envoy_memory` table if it does not already exist.
  ///
  /// Safe to call on every startup (idempotent).
  @override
  Future<void> initialize() async {
    await _stanza.rawExecute('''
      CREATE TABLE IF NOT EXISTS envoy_memory (
        id         SERIAL PRIMARY KEY,
        type       TEXT NOT NULL,
        content    TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
  }

  /// Persists a single memory entry.
  @override
  Future<void> remember(MemoryEntry entry) async {
    final entity = MemoryEntity()
      ..type = entry.type
      ..content = entry.content
      ..createdAt = entry.createdAt;

    await _stanza.execute(
      InsertQuery(MemoryEntity.$table)..insertEntity<MemoryEntity>(entity),
    );
  }

  /// Returns stored entries, optionally filtered by [type] or [query] (FTS).
  ///
  /// Results are ordered by recency (newest first).
  @override
  Future<List<MemoryEntry>> recall({String? type, String? query}) async {
    final t = MemoryEntity.$table;
    final q = SelectQuery(t)
      ..selectStar()
      ..orderBy(t.createdAt, descending: true);

    if (type != null && query != null) {
      q
        ..where(t.type).matches(type, caseSensitive: false)
        ..and(t.content).fullTextMatches(query);
    } else if (type != null) {
      q..where(t.type).matches(type, caseSensitive: false);
    } else if (query != null) {
      q..where(t.content).fullTextMatches(query);
    }

    final result = await _stanza.execute<MemoryEntity>(q);
    return result.entities
        .map((e) => MemoryEntry(
              type: e.type,
              content: e.content,
              createdAt: e.createdAt,
            ))
        .toList();
  }
}
