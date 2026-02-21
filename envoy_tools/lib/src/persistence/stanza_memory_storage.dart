import 'package:envoy/envoy.dart';
import 'package:stanza/stanza.dart';

import 'memory_entity.dart';

/// Table descriptor — instantiated once and reused across queries.
final _memory = $MemoryEntityTable();

/// Stanza-backed implementation of [AgentMemory].
///
/// Persists agent self-memory entries to the `envoy_memory` table.
/// Entries are written by [EnvoyAgent.reflect] after each session.
///
/// ## Setup
///
/// ```dart
/// final memory = StanzaMemoryStorage(db); // db is a DatabaseAdapter
/// await memory.initialize();
///
/// final agent = EnvoyAgent(config, memory: memory, ...);
///
/// final result = await agent.run(task);
/// await agent.reflect();  // agent decides what to remember
///
/// // Inspect what was stored:
/// final entries = await memory.recall();
/// for (final e in entries) print('[${e.type}] ${e.content}');
/// ```
class StanzaMemoryStorage implements AgentMemory {
  final DatabaseAdapter _db;

  StanzaMemoryStorage(this._db);

  /// Creates the `envoy_memory` table if it does not already exist.
  ///
  /// Safe to call on every startup (idempotent).
  @override
  Future<void> initialize() async {
    await _db.rawExecute('''
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
    await _db.execute(
      InsertQuery(_memory).values(
        MemoryEntityInsert(
          type: entry.type,
          content: entry.content,
        ).toRow(),
      ),
    );
  }

  /// Returns stored entries, optionally filtered by [type] or [query] (FTS).
  ///
  /// Results are ordered by recency (newest first).
  @override
  Future<List<MemoryEntry>> recall({String? type, String? query}) async {
    var q = SelectQuery(_memory)
        .orderBy((t) => t.createdAt.desc());

    if (type != null && query != null) {
      q = q.where((t) => t.type.ilike(type) & t.content.fullTextMatches(query));
    } else if (type != null) {
      q = q.where((t) => t.type.ilike(type));
    } else if (query != null) {
      q = q.where((t) => t.content.fullTextMatches(query));
    }

    final result = await _db.execute(q);
    return result.entities
        .map((e) => MemoryEntry(
              type: e.type,
              content: e.content,
              createdAt: e.createdAt,
            ))
        .toList();
  }
}
