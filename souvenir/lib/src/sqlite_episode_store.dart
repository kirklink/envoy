import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'episode_store.dart';
import 'models/episode.dart';

/// SQLite-backed implementation of [EpisodeStore].
///
/// Persists episodes so unconsolidated ones survive process restarts —
/// the requirement [InMemoryEpisodeStore] cannot meet for long-running
/// servers. The table name is prefixed with [prefix] to support
/// multi-agent isolation in a shared database, matching
/// `SqliteMemoryStore`.
class SqliteEpisodeStore implements EpisodeStore {
  final sqlite3.Database _db;
  final String _prefix;

  String get _episodes => '${_prefix}episodes';

  /// Creates a SQLite episode store.
  ///
  /// [db] is a raw sqlite3 database (e.g., from `sqlite3.openInMemory()`
  /// or `tureen.database`); it may be shared with a `SqliteMemoryStore`.
  /// [prefix] is prepended to the table name for multi-agent isolation.
  SqliteEpisodeStore(this._db, {String prefix = ''}) : _prefix = prefix;

  /// Creates the episodes table and indexes. Idempotent; call at boot.
  Future<void> initialize() async {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_episodes (
        id             TEXT PRIMARY KEY,
        session_id     TEXT NOT NULL,
        timestamp      TEXT NOT NULL,
        type           TEXT NOT NULL,
        content        TEXT NOT NULL,
        importance     REAL NOT NULL DEFAULT 0.5,
        access_count   INTEGER NOT NULL DEFAULT 0,
        last_accessed  TEXT,
        consolidated   INTEGER NOT NULL DEFAULT 0
      )
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS ${_prefix}idx_episodes_consolidated
        ON $_episodes(consolidated, timestamp)
    ''');
  }

  @override
  Future<void> insert(List<Episode> episodes) async {
    final stmt = _db.prepare(
      'INSERT OR REPLACE INTO $_episodes '
      '(id, session_id, timestamp, type, content, importance, '
      'access_count, last_accessed, consolidated) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    );
    try {
      for (final e in episodes) {
        stmt.execute([
          e.id,
          e.sessionId,
          e.timestamp.toUtc().toIso8601String(),
          e.type.name,
          e.content,
          e.importance,
          e.accessCount,
          e.lastAccessed?.toUtc().toIso8601String(),
          e.consolidated ? 1 : 0,
        ]);
      }
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<Episode>> fetchUnconsolidated() async {
    final result = _db.select(
      'SELECT * FROM $_episodes WHERE consolidated = 0 ORDER BY timestamp',
    );
    return result.map(_rowToEpisode).toList();
  }

  @override
  Future<void> markConsolidated(List<Episode> episodes) async {
    if (episodes.isEmpty) return;
    final placeholders = List.filled(episodes.length, '?').join(', ');
    _db.execute(
      'UPDATE $_episodes SET consolidated = 1 WHERE id IN ($placeholders)',
      episodes.map((e) => e.id).toList(),
    );
  }

  @override
  Future<int> deleteConsolidatedBefore(DateTime olderThan) async {
    _db.execute(
      'DELETE FROM $_episodes WHERE consolidated = 1 AND timestamp < ?',
      [olderThan.toUtc().toIso8601String()],
    );
    return _db.updatedRows;
  }

  /// Total episodes stored (observability convenience).
  int get length {
    final result = _db.select('SELECT COUNT(*) AS cnt FROM $_episodes');
    return result.first['cnt'] as int;
  }

  @override
  int get unconsolidatedCount {
    final result = _db.select(
      'SELECT COUNT(*) AS cnt FROM $_episodes WHERE consolidated = 0',
    );
    return result.first['cnt'] as int;
  }

  @override
  DateTime? get oldestUnconsolidatedAt {
    final result = _db.select(
      'SELECT MIN(timestamp) AS oldest FROM $_episodes '
      'WHERE consolidated = 0',
    );
    final oldest = result.first['oldest'] as String?;
    return oldest == null ? null : DateTime.parse(oldest);
  }

  Episode _rowToEpisode(sqlite3.Row row) {
    return Episode(
      id: row['id'] as String,
      sessionId: row['session_id'] as String,
      timestamp: DateTime.parse(row['timestamp'] as String),
      type: EpisodeType.values.firstWhere((t) => t.name == row['type']),
      content: row['content'] as String,
      importance: (row['importance'] as num).toDouble(),
      accessCount: row['access_count'] as int,
      lastAccessed: row['last_accessed'] != null
          ? DateTime.parse(row['last_accessed'] as String)
          : null,
      consolidated: (row['consolidated'] as int) == 1,
    );
  }
}
