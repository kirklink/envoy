import 'package:stanza/stanza.dart';

import 'episode_store.dart';
import 'models/episode.dart';

/// SQLite-backed [EpisodeStore] for production use.
///
/// Stores episodes in a `souvenir_episodes` table. The engine owns
/// episode lifecycle (insert, fetch unconsolidated, mark consolidated).
///
/// Requires [initialize] to be called before use to create the table.
class SqliteEpisodeStore implements EpisodeStore {
  final DatabaseAdapter _db;

  SqliteEpisodeStore(this._db);

  /// Creates the episodes table. Idempotent.
  Future<void> initialize() async {
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS souvenir_episodes (
        id            TEXT PRIMARY KEY,
        session_id    TEXT NOT NULL,
        timestamp     TEXT NOT NULL,
        type          TEXT NOT NULL,
        content       TEXT NOT NULL,
        importance    REAL NOT NULL DEFAULT 0.5,
        access_count  INTEGER NOT NULL DEFAULT 0,
        last_accessed TEXT,
        consolidated  INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  @override
  Future<void> insert(List<Episode> episodes) async {
    if (episodes.isEmpty) return;

    await _db.transaction((session) async {
      for (final ep in episodes) {
        await session.rawExecute(
          'INSERT INTO souvenir_episodes '
          '(id, session_id, timestamp, type, content, importance, '
          'access_count, consolidated) '
          'VALUES (:id, :sessionId, :timestamp, :type, :content, '
          ':importance, :accessCount, :consolidated)',
          parameters: {
            ':id': ep.id,
            ':sessionId': ep.sessionId,
            ':timestamp': ep.timestamp.toUtc().toIso8601String(),
            ':type': ep.type.name,
            ':content': ep.content,
            ':importance': ep.importance,
            ':accessCount': ep.accessCount,
            ':consolidated': ep.consolidated ? 1 : 0,
          },
        );
      }
    });
  }

  @override
  Future<List<Episode>> fetchUnconsolidated() async {
    final result = await _db.rawExecute(
      'SELECT * FROM souvenir_episodes '
      'WHERE consolidated = 0 '
      'ORDER BY timestamp',
    );

    return result.rows.map(_rowToEpisode).toList();
  }

  @override
  Future<void> markConsolidated(List<Episode> episodes) async {
    if (episodes.isEmpty) return;

    await _db.transaction((session) async {
      for (final ep in episodes) {
        await session.rawExecute(
          'UPDATE souvenir_episodes SET consolidated = 1 WHERE id = :id',
          parameters: {':id': ep.id},
        );
      }
    });
  }

  /// Total number of episodes (testing convenience).
  Future<int> count() async {
    final result = await _db.rawExecute(
      'SELECT COUNT(*) as cnt FROM souvenir_episodes',
    );
    return result.rows.first['cnt'] as int;
  }

  /// Number of unconsolidated episodes (testing convenience).
  Future<int> unconsolidatedCount() async {
    final result = await _db.rawExecute(
      'SELECT COUNT(*) as cnt FROM souvenir_episodes WHERE consolidated = 0',
    );
    return result.rows.first['cnt'] as int;
  }

  static Episode _rowToEpisode(Map<String, dynamic> row) {
    return Episode(
      id: row['id'] as String,
      sessionId: row['session_id'] as String,
      timestamp: DateTime.parse(row['timestamp'] as String),
      type: EpisodeType.values.firstWhere(
        (t) => t.name == (row['type'] as String),
      ),
      content: row['content'] as String,
      importance: (row['importance'] as num).toDouble(),
      accessCount: (row['access_count'] as num).toInt(),
      consolidated: (row['consolidated'] as int) == 1,
    );
  }
}
