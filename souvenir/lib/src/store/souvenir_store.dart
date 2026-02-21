import 'dart:convert';
import 'dart:typed_data';

import 'package:stanza/stanza.dart' hide Entity;
import 'package:stanza_sqlite/stanza_sqlite.dart';

import '../models/entity.dart';
import '../models/episode.dart';
import '../models/memory.dart';
import '../models/relationship.dart';
import 'entity_entity.dart';
import 'episode_entity.dart';
import 'memory_entity.dart';
import 'relationship_entity.dart';
import 'schema.dart';

final _episodes = $EpisodeEntityTable();
final _memories = $MemoryEntityTable();
final _entities = $EntityRecordTable();
final _relationships = $RelationshipRecordTable();

/// Low-level SQLite operations for the souvenir memory system.
class SouvenirStore {
  final StanzaSqlite _db;

  SouvenirStore(this._db);

  /// Sanitizes a raw text string for use in FTS5 MATCH queries.
  ///
  /// FTS5 interprets special characters (`.`, `:`, `(`, `)`, `-`, etc.) as
  /// query syntax. Raw content strings — especially LLM-generated text —
  /// contain these characters freely and cause parse errors.
  ///
  /// This method wraps each word in double quotes so FTS5 treats them as
  /// literal tokens. Empty input returns an empty string (caller should
  /// guard against passing it to MATCH).
  static String _sanitizeFtsQuery(String raw) {
    // Extract alphanumeric tokens, drop everything else.
    final tokens = raw
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return '""';
    // Quote each token to prevent FTS5 syntax errors.
    return tokens.map((t) => '"$t"').join(' ');
  }

  // ── Initialization ────────────────────────────────────────────────────────

  /// Creates all tables and FTS5 indexes. Idempotent.
  Future<void> initialize() async {
    // Tier 1: Episodic memory.
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS episodes (
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

    await _createFts5IfNeeded(episodesFts);

    // Tier 2: Semantic memory.
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS memories (
        id            TEXT PRIMARY KEY,
        content       TEXT NOT NULL,
        entity_ids    TEXT,
        importance    REAL NOT NULL DEFAULT 0.5,
        embedding     BLOB,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL,
        source_ids    TEXT,
        access_count  INTEGER NOT NULL DEFAULT 0,
        last_accessed TEXT
      )
    ''');

    await _createFts5IfNeeded(memoriesFts);

    // Knowledge graph.
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS entities (
        id    TEXT PRIMARY KEY,
        name  TEXT NOT NULL UNIQUE,
        type  TEXT NOT NULL
      )
    ''');

    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS relationships (
        from_entity TEXT NOT NULL,
        to_entity   TEXT NOT NULL,
        relation    TEXT NOT NULL,
        confidence  REAL NOT NULL DEFAULT 1.0,
        updated_at  TEXT NOT NULL,
        PRIMARY KEY (from_entity, to_entity, relation)
      )
    ''');

    // Personality key-value store.
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS personality (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // Personality history snapshots.
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS personality_history (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        content    TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // Procedural memory: success/failure patterns per task type.
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS patterns (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        task_type  TEXT NOT NULL,
        success    INTEGER NOT NULL,
        session_id TEXT NOT NULL,
        notes      TEXT,
        created_at TEXT NOT NULL
      )
    ''');
  }

  // ── Episode operations ────────────────────────────────────────────────────

  /// Batch-inserts episodes into the database.
  ///
  /// FTS5 index is updated automatically via triggers.
  Future<void> insertEpisodes(List<Episode> episodes) async {
    if (episodes.isEmpty) return;

    await _db.transaction((session) async {
      for (final ep in episodes) {
        await session.execute(
          InsertQuery(_episodes).values(
            EpisodeEntityInsert(
              id: ep.id,
              sessionId: ep.sessionId,
              timestamp: ep.timestamp,
              type: ep.type.name,
              content: ep.content,
              importance: ep.importance,
              accessCount: ep.accessCount,
              consolidated: ep.consolidated ? 1 : 0,
            ).toRow(),
          ),
        );
      }
    });
  }

  /// Full-text search over episodes using BM25 ranking.
  ///
  /// Uses raw SQL because the FTS5 index maps to SQLite's implicit integer
  /// `rowid` (our PK is TEXT ULID, which can't alias `rowid`). Stanza's
  /// typed `fts5Join` requires a typed column, so we join manually.
  Future<List<({EpisodeEntity entity, double score})>> searchEpisodes(
    String query, {
    int limit = 10,
    String? sessionId,
  }) async {
    final sanitized = _sanitizeFtsQuery(query);
    final sessionFilter =
        sessionId != null ? 'AND e.session_id = :sessionId ' : '';
    final params = <String, dynamic>{
      ':query': sanitized,
      ':limit': limit,
      if (sessionId != null) ':sessionId': sessionId,
    };

    final result = await _db.rawExecute(
      'SELECT e.*, bm25(${episodesFts.tableName}) AS rank '
      'FROM episodes e '
      'JOIN ${episodesFts.tableName} ON e.rowid = ${episodesFts.tableName}.rowid '
      'WHERE ${episodesFts.tableName} MATCH :query '
      '$sessionFilter'
      'ORDER BY rank '
      'LIMIT :limit',
      parameters: params,
    );

    return result.rows.map((row) {
      final score = -(row['rank'] as num).toDouble();
      final converted = _convertEpisodeRow(row);
      return (entity: _episodes.fromRow(converted), score: score);
    }).toList();
  }

  /// Returns recent episodes ordered by timestamp descending.
  Future<List<EpisodeEntity>> recentEpisodes({
    String? sessionId,
    int limit = 20,
  }) async {
    var q = SelectQuery(_episodes)
        .orderBy((t) => t.timestamp.desc())
        .limit(limit);

    if (sessionId != null) {
      q = q.where((t) => t.sessionId.equals(sessionId));
    }

    final result = await _db.execute(q);
    return result.entities.cast<EpisodeEntity>();
  }

  /// Returns unconsolidated episodes older than [minAge].
  ///
  /// Results are ordered by session_id then timestamp for grouping.
  Future<List<EpisodeEntity>> unconsolidatedEpisodes({
    required Duration minAge,
  }) async {
    final cutoff =
        DateTime.now().subtract(minAge).toUtc().toIso8601String();
    final result = await _db.rawExecute(
      'SELECT * FROM episodes '
      'WHERE consolidated = 0 AND timestamp < :cutoff '
      'ORDER BY session_id, timestamp',
      parameters: {':cutoff': cutoff},
    );

    return result.rows.map((row) {
      final converted = _convertEpisodeRow(row);
      return _episodes.fromRow(converted);
    }).toList();
  }

  /// Marks episodes as consolidated.
  Future<void> markConsolidated(List<String> episodeIds) async {
    if (episodeIds.isEmpty) return;

    await _db.transaction((session) async {
      for (final id in episodeIds) {
        await session.rawExecute(
          'UPDATE episodes SET consolidated = 1 WHERE id = :id',
          parameters: {':id': id},
        );
      }
    });
  }

  /// Bumps access_count and last_accessed for episodes.
  Future<void> updateAccessStats(List<String> ids) async {
    if (ids.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      await _db.rawExecute(
        'UPDATE episodes SET access_count = access_count + 1, '
        'last_accessed = :now WHERE id = :id',
        parameters: {':now': now, ':id': id},
      );
    }
  }

  /// Returns the total number of episodes in the database.
  Future<int> episodeCount() async {
    final result = await _db.rawExecute(
      'SELECT COUNT(*) as cnt FROM episodes',
    );
    return result.rows.first['cnt'] as int;
  }

  // ── Memory operations ─────────────────────────────────────────────────────

  /// Inserts a semantic memory.
  Future<void> insertMemory(Memory memory) async {
    await _db.transaction((session) async {
      await session.execute(
        InsertQuery(_memories).values(
          MemoryEntityInsert(
            id: memory.id,
            content: memory.content,
            entityIds: memory.entityIds.isEmpty
                ? null
                : jsonEncode(memory.entityIds),
            importance: memory.importance,
            createdAt: memory.createdAt,
            updatedAt: memory.updatedAt,
            sourceIds: memory.sourceEpisodeIds.isEmpty
                ? null
                : jsonEncode(memory.sourceEpisodeIds),
            accessCount: memory.accessCount,
          ).toRow(),
        ),
      );
    });
  }

  /// Partially updates a memory. Only non-null fields are updated.
  Future<void> updateMemory(
    String id, {
    String? content,
    double? importance,
    List<String>? entityIds,
    List<String>? sourceIds,
  }) async {
    final sets = <String>[];
    final params = <String, dynamic>{':id': id};

    if (content != null) {
      sets.add('content = :content');
      params[':content'] = content;
    }
    if (importance != null) {
      sets.add('importance = :importance');
      params[':importance'] = importance;
    }
    if (entityIds != null) {
      sets.add('entity_ids = :entityIds');
      params[':entityIds'] = jsonEncode(entityIds);
    }
    if (sourceIds != null) {
      sets.add('source_ids = :sourceIds');
      params[':sourceIds'] = jsonEncode(sourceIds);
    }

    // Always bump updated_at.
    sets.add('updated_at = :updatedAt');
    params[':updatedAt'] = DateTime.now().toUtc().toIso8601String();

    if (sets.isEmpty) return;

    await _db.rawExecute(
      'UPDATE memories SET ${sets.join(', ')} WHERE id = :id',
      parameters: params,
    );
  }

  /// Full-text search over semantic memories using BM25 ranking.
  Future<List<({MemoryEntity entity, double score})>> searchMemories(
    String query, {
    int limit = 10,
  }) async {
    final sanitized = _sanitizeFtsQuery(query);
    final result = await _db.rawExecute(
      'SELECT m.*, bm25(${memoriesFts.tableName}) AS rank '
      'FROM memories m '
      'JOIN ${memoriesFts.tableName} ON m.rowid = ${memoriesFts.tableName}.rowid '
      'WHERE ${memoriesFts.tableName} MATCH :query '
      'ORDER BY rank '
      'LIMIT :limit',
      parameters: {':query': sanitized, ':limit': limit},
    );

    return result.rows.map((row) {
      final score = -(row['rank'] as num).toDouble();
      final converted = _convertMemoryRow(row);
      return (entity: _memories.fromRow(converted), score: score);
    }).toList();
  }

  /// Bumps access_count and last_accessed for memories.
  Future<void> updateMemoryAccessStats(List<String> ids) async {
    if (ids.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      await _db.rawExecute(
        'UPDATE memories SET access_count = access_count + 1, '
        'last_accessed = :now WHERE id = :id',
        parameters: {':now': now, ':id': id},
      );
    }
  }

  /// Returns the total number of memories.
  Future<int> memoryCount() async {
    final result = await _db.rawExecute(
      'SELECT COUNT(*) as cnt FROM memories',
    );
    return result.rows.first['cnt'] as int;
  }

  // ── Embedding operations ──────────────────────────────────────────────────

  /// Stores an embedding vector for a memory as a BLOB.
  ///
  /// Converts the [embedding] to a [Float32List] and stores the raw bytes.
  Future<void> updateMemoryEmbedding(
    String id,
    List<double> embedding,
  ) async {
    final blob = _embeddingToBlob(embedding);
    await _db.rawExecute(
      'UPDATE memories SET embedding = :embedding WHERE id = :id',
      parameters: {':embedding': blob, ':id': id},
    );
  }

  /// Loads all memories that have embeddings, returning parsed vectors.
  ///
  /// Used by the retrieval pipeline for cosine similarity search.
  Future<List<MemoryWithEmbedding>> loadMemoriesWithEmbeddings() async {
    final result = await _db.rawExecute(
      'SELECT id, content, embedding, updated_at, importance, access_count '
      'FROM memories WHERE embedding IS NOT NULL',
    );

    return result.rows.map((row) {
      final blob = row['embedding'] as Uint8List;
      return MemoryWithEmbedding(
        id: row['id'] as String,
        content: row['content'] as String,
        embedding: _blobToEmbedding(blob),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        importance: (row['importance'] as num).toDouble(),
        accessCount: (row['access_count'] as num).toInt(),
      );
    }).toList();
  }

  /// Converts a [List<double>] embedding to BLOB bytes.
  static Uint8List _embeddingToBlob(List<double> embedding) {
    final float32 = Float32List.fromList(embedding);
    return float32.buffer.asUint8List();
  }

  /// Converts BLOB bytes back to a [List<double>] embedding.
  static List<double> _blobToEmbedding(Uint8List blob) {
    // Copy to an aligned buffer — raw SQLite bytes may not be Float32-aligned.
    final aligned = Float32List(blob.length ~/ 4);
    aligned.buffer.asUint8List().setAll(0, blob);
    return aligned.toList();
  }

  // ── Entity operations ─────────────────────────────────────────────────────

  /// Finds an entity by exact name match.
  Future<EntityRecord?> findEntityByName(String name) async {
    final result = await _db.execute(
      SelectQuery(_entities).where((t) => t.name.equals(name)),
    );
    return result.isEmpty ? null : result.entities.first as EntityRecord;
  }

  /// Inserts or replaces an entity (upsert by name).
  Future<void> upsertEntity(Entity entity) async {
    await _db.rawExecute(
      'INSERT OR REPLACE INTO entities (id, name, type) '
      'VALUES (:id, :name, :type)',
      parameters: {
        ':id': entity.id,
        ':name': entity.name,
        ':type': entity.type.name,
      },
    );
  }

  /// Finds an entity by its ID.
  Future<EntityRecord?> findEntityById(String id) async {
    final result = await _db.execute(
      SelectQuery(_entities).where((t) => t.id.equals(id)),
    );
    return result.isEmpty ? null : result.entities.first as EntityRecord;
  }

  /// Finds entities whose names appear in the [query] text.
  ///
  /// Performs case-insensitive substring matching. Loads all entities and
  /// filters in Dart — the entities table is small by design.
  Future<List<EntityRecord>> findEntitiesByNameMatch(String query) async {
    final result = await _db.execute(SelectQuery(_entities));
    final entities = result.entities.cast<EntityRecord>();
    final lowerQuery = query.toLowerCase();
    return entities
        .where((e) => lowerQuery.contains(e.name.toLowerCase()))
        .toList();
  }

  // ── Relationship operations ───────────────────────────────────────────────

  /// Inserts or replaces a relationship (upsert by composite PK).
  Future<void> upsertRelationship(Relationship rel) async {
    await _db.rawExecute(
      'INSERT OR REPLACE INTO relationships '
      '(from_entity, to_entity, relation, confidence, updated_at) '
      'VALUES (:from, :to, :rel, :conf, :updated)',
      parameters: {
        ':from': rel.fromEntityId,
        ':to': rel.toEntityId,
        ':rel': rel.relation,
        ':conf': rel.confidence,
        ':updated': rel.updatedAt.toUtc().toIso8601String(),
      },
    );
  }

  /// Returns all relationships connected to [entityId] (either direction).
  Future<List<RelationshipRecord>> findRelationshipsForEntity(
    String entityId,
  ) async {
    final result = await _db.rawExecute(
      'SELECT * FROM relationships '
      'WHERE from_entity = :id OR to_entity = :id',
      parameters: {':id': entityId},
    );

    return result.rows.map((row) {
      final converted = _convertRelationshipRow(row);
      return _relationships.fromRow(converted);
    }).toList();
  }

  // ── Memory-by-entity queries ────────────────────────────────────────────

  /// Finds memories associated with any of the given [entityIds].
  ///
  /// Queries the JSON-encoded `entity_ids` column using SQLite `json_each()`.
  Future<List<MemoryEntity>> findMemoriesByEntityIds(
    List<String> entityIds,
  ) async {
    if (entityIds.isEmpty) return [];

    final placeholders = <String>[];
    final params = <String, dynamic>{};
    for (var i = 0; i < entityIds.length; i++) {
      placeholders.add(':eid$i');
      params[':eid$i'] = entityIds[i];
    }

    final result = await _db.rawExecute(
      'SELECT DISTINCT m.* FROM memories m, json_each(m.entity_ids) je '
      'WHERE je.value IN (${placeholders.join(', ')})',
      parameters: params,
    );

    return result.rows.map((row) {
      final converted = _convertMemoryRow(row);
      return _memories.fromRow(converted);
    }).toList();
  }

  /// Fetches memories by their IDs, preserving the given order.
  Future<List<MemoryEntity>> findMemoriesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];

    final placeholders = <String>[];
    final params = <String, dynamic>{};
    for (var i = 0; i < ids.length; i++) {
      placeholders.add(':id$i');
      params[':id$i'] = ids[i];
    }

    final result = await _db.rawExecute(
      'SELECT * FROM memories WHERE id IN (${placeholders.join(', ')})',
      parameters: params,
    );

    final entities = result.rows.map((row) {
      final converted = _convertMemoryRow(row);
      return _memories.fromRow(converted);
    }).toList();

    // Preserve requested order.
    final byId = {for (final e in entities) e.id: e};
    return ids.where(byId.containsKey).map((id) => byId[id]!).toList();
  }

  // ── Importance decay ──────────────────────────────────────────────────────

  /// Decays importance of memories not accessed within [inactivePeriod].
  ///
  /// Returns the number of memories affected.
  Future<int> applyImportanceDecay({
    required Duration inactivePeriod,
    required double decayRate,
  }) async {
    final cutoff =
        DateTime.now().subtract(inactivePeriod).toUtc().toIso8601String();
    final result = await _db.rawExecute(
      'UPDATE memories SET importance = importance * :rate '
      'WHERE (last_accessed IS NOT NULL AND last_accessed < :cutoff) '
      'OR (last_accessed IS NULL AND updated_at < :cutoff)',
      parameters: {':rate': decayRate, ':cutoff': cutoff},
    );
    return result.affectedRows;
  }

  // ── Personality operations ────────────────────────────────────────────────

  /// Returns the current personality text, or null if not set.
  Future<String?> getPersonality() async {
    final result = await _db.rawExecute(
      "SELECT value FROM personality WHERE key = 'text'",
    );
    return result.isEmpty ? null : result.rows.first['value'] as String;
  }

  /// Returns when the personality was last updated, or null if never set.
  Future<DateTime?> getPersonalityLastUpdated() async {
    final result = await _db.rawExecute(
      "SELECT value FROM personality WHERE key = 'last_updated'",
    );
    if (result.isEmpty) return null;
    return DateTime.parse(result.rows.first['value'] as String);
  }

  /// Saves personality text, snapshotting the current text to history first.
  ///
  /// If there is no current personality (initial seed), no snapshot is created.
  Future<void> savePersonality(String text) async {
    final now = DateTime.now().toUtc().toIso8601String();

    await _db.transaction((session) async {
      // Snapshot current text to history (if any).
      final existing = await session.rawExecute(
        "SELECT value FROM personality WHERE key = 'text'",
      );
      if (existing.isNotEmpty) {
        final oldText = existing.rows.first['value'] as String;
        await session.rawExecute(
          'INSERT INTO personality_history (content, created_at) '
          'VALUES (:content, :created)',
          parameters: {':content': oldText, ':created': now},
        );
      }

      // Upsert current personality text.
      await session.rawExecute(
        "INSERT OR REPLACE INTO personality (key, value) VALUES ('text', :text)",
        parameters: {':text': text},
      );

      // Upsert last_updated timestamp.
      await session.rawExecute(
        "INSERT OR REPLACE INTO personality (key, value) "
        "VALUES ('last_updated', :now)",
        parameters: {':now': now},
      );
    });
  }

  /// Saves personality text without creating a history snapshot.
  ///
  /// Used for the initial seed (identity → personality) where there is no
  /// prior text to snapshot.
  Future<void> initPersonality(String text) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.rawExecute(
      "INSERT OR REPLACE INTO personality (key, value) VALUES ('text', :text)",
      parameters: {':text': text},
    );
    await _db.rawExecute(
      "INSERT OR REPLACE INTO personality (key, value) "
      "VALUES ('last_updated', :now)",
      parameters: {':now': now},
    );
  }

  /// Returns personality history snapshots, newest first.
  Future<List<({String content, DateTime createdAt})>> personalityHistory({
    int limit = 20,
  }) async {
    final result = await _db.rawExecute(
      'SELECT content, created_at FROM personality_history '
      'ORDER BY created_at DESC LIMIT :limit',
      parameters: {':limit': limit},
    );
    return result.rows.map((row) {
      return (
        content: row['content'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
    }).toList();
  }

  /// Returns the nearest personality snapshot on or before [date].
  Future<String?> personalityHistoryAt(DateTime date) async {
    final result = await _db.rawExecute(
      'SELECT content FROM personality_history '
      'WHERE created_at <= :date ORDER BY created_at DESC LIMIT 1',
      parameters: {':date': date.toUtc().toIso8601String()},
    );
    return result.isEmpty ? null : result.rows.first['content'] as String;
  }

  // ── Pattern operations ───────────────────────────────────────────────────

  /// Records a task outcome (success or failure) for pattern tracking.
  Future<void> insertPattern({
    required String taskType,
    required bool success,
    required String sessionId,
    String? notes,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.rawExecute(
      'INSERT INTO patterns (task_type, success, session_id, notes, created_at) '
      'VALUES (:type, :success, :session, :notes, :created)',
      parameters: {
        ':type': taskType,
        ':success': success ? 1 : 0,
        ':session': sessionId,
        ':notes': notes,
        ':created': now,
      },
    );
  }

  /// Returns aggregate stats and recent failure notes for a task type.
  Future<({int successes, int failures, List<String> recentNotes})>
      getPatternStats(String taskType, {int noteLimit = 3}) async {
    final countResult = await _db.rawExecute(
      'SELECT '
      'SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) AS successes, '
      'SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) AS failures '
      'FROM patterns WHERE task_type = :type',
      parameters: {':type': taskType},
    );

    final row = countResult.rows.first;
    final successes = (row['successes'] as num?)?.toInt() ?? 0;
    final failures = (row['failures'] as num?)?.toInt() ?? 0;

    final notesResult = await _db.rawExecute(
      'SELECT notes FROM patterns '
      'WHERE task_type = :type AND success = 0 AND notes IS NOT NULL '
      'ORDER BY created_at DESC LIMIT :limit',
      parameters: {':type': taskType, ':limit': noteLimit},
    );

    final recentNotes =
        notesResult.rows.map((r) => r['notes'] as String).toList();

    return (
      successes: successes,
      failures: failures,
      recentNotes: recentNotes,
    );
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Converts raw episode row DateTime strings to objects and strips extras.
  static Map<String, dynamic> _convertEpisodeRow(Map<String, dynamic> row) {
    final converted = Map<String, dynamic>.from(row);
    if (converted['timestamp'] is String) {
      converted['timestamp'] =
          DateTime.parse(converted['timestamp'] as String);
    }
    if (converted['last_accessed'] is String) {
      converted['last_accessed'] =
          DateTime.parse(converted['last_accessed'] as String);
    }
    converted.remove('rank');
    return converted;
  }

  /// Converts raw memory row DateTime strings to objects and strips extras.
  ///
  /// The `embedding` column stores a BLOB (Uint8List) but the Stanza-generated
  /// entity expects `String?`. We null it out here — embedding data is accessed
  /// via [loadMemoriesWithEmbeddings] instead.
  static Map<String, dynamic> _convertMemoryRow(Map<String, dynamic> row) {
    final converted = Map<String, dynamic>.from(row);
    if (converted['created_at'] is String) {
      converted['created_at'] =
          DateTime.parse(converted['created_at'] as String);
    }
    if (converted['updated_at'] is String) {
      converted['updated_at'] =
          DateTime.parse(converted['updated_at'] as String);
    }
    if (converted['last_accessed'] is String) {
      converted['last_accessed'] =
          DateTime.parse(converted['last_accessed'] as String);
    }
    // BLOB embedding can't be cast to String? — strip it for typed entity.
    if (converted['embedding'] is Uint8List) {
      converted['embedding'] = null;
    }
    converted.remove('rank');
    return converted;
  }

  /// Converts raw relationship row DateTime strings to objects.
  static Map<String, dynamic> _convertRelationshipRow(
    Map<String, dynamic> row,
  ) {
    final converted = Map<String, dynamic>.from(row);
    if (converted['updated_at'] is String) {
      converted['updated_at'] =
          DateTime.parse(converted['updated_at'] as String);
    }
    return converted;
  }

  Future<void> _createFts5IfNeeded(Fts5Index index) async {
    final exists = await _fts5TableExists(index.tableName);
    if (!exists) {
      await _db.rawExecute(SqliteDdl.createFts5Table(index));
      for (final trigger in SqliteDdl.createFts5Triggers(index)) {
        await _db.rawExecute(trigger);
      }
    }
  }

  Future<bool> _fts5TableExists(String tableName) async {
    final result = await _db.rawExecute(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = :name",
      parameters: {':name': tableName},
    );
    return result.isNotEmpty;
  }
}

/// A memory record with its parsed embedding vector.
///
/// Used by the retrieval pipeline for vector similarity search.
class MemoryWithEmbedding {
  final String id;
  final String content;
  final List<double> embedding;
  final DateTime updatedAt;
  final double importance;
  final int accessCount;

  const MemoryWithEmbedding({
    required this.id,
    required this.content,
    required this.embedding,
    required this.updatedAt,
    required this.importance,
    required this.accessCount,
  });
}
