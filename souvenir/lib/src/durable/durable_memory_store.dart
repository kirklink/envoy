import 'dart:convert';
import 'dart:typed_data';

import 'package:stanza/stanza.dart';
import 'package:stanza_sqlite/stanza_sqlite.dart';

import 'stored_memory.dart';

/// FTS5 index for full-text search over durable memory content.
const _durableMemoriesFts = Fts5Index(
  sourceTable: 'durable_memories',
  columns: ['content'],
  tokenize: 'porter unicode61',
);

/// Low-level SQLite operations for the durable memory component.
///
/// All tables are prefixed with `durable_` to avoid collisions with other
/// components sharing the same database. Uses raw SQL — no code gen.
class DurableMemoryStore {
  final DatabaseAdapter _db;

  DurableMemoryStore(this._db);

  // ── Initialization ──────────────────────────────────────────────────────

  /// Creates all tables and FTS5 indexes. Idempotent.
  Future<void> initialize() async {
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS durable_memories (
        id            TEXT PRIMARY KEY,
        content       TEXT NOT NULL,
        entity_ids    TEXT,
        importance    REAL NOT NULL DEFAULT 0.5,
        embedding     BLOB,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL,
        source_ids    TEXT,
        access_count  INTEGER NOT NULL DEFAULT 0,
        last_accessed TEXT,
        status        TEXT NOT NULL DEFAULT 'active',
        superseded_by TEXT,
        valid_at      TEXT,
        invalid_at    TEXT
      )
    ''');

    await _createFts5IfNeeded();

    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS durable_entities (
        id    TEXT PRIMARY KEY,
        name  TEXT NOT NULL UNIQUE,
        type  TEXT NOT NULL
      )
    ''');

    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS durable_relationships (
        from_entity TEXT NOT NULL,
        to_entity   TEXT NOT NULL,
        relation    TEXT NOT NULL,
        confidence  REAL NOT NULL DEFAULT 1.0,
        updated_at  TEXT NOT NULL,
        PRIMARY KEY (from_entity, to_entity, relation)
      )
    ''');
  }

  // ── Memory operations ─────────────────────────────────────────────────

  /// Inserts a durable memory.
  Future<void> insertMemory(StoredMemory memory) async {
    await _db.rawExecute(
      'INSERT INTO durable_memories '
      '(id, content, entity_ids, importance, created_at, updated_at, '
      'source_ids, access_count, status, superseded_by, valid_at, invalid_at) '
      'VALUES (:id, :content, :entityIds, :importance, :createdAt, :updatedAt, '
      ':sourceIds, :accessCount, :status, :supersededBy, :validAt, :invalidAt)',
      parameters: {
        ':id': memory.id,
        ':content': memory.content,
        ':entityIds': memory.entityIds.isEmpty
            ? null
            : jsonEncode(memory.entityIds),
        ':importance': memory.importance,
        ':createdAt': memory.createdAt.toUtc().toIso8601String(),
        ':updatedAt': memory.updatedAt.toUtc().toIso8601String(),
        ':sourceIds': memory.sourceEpisodeIds.isEmpty
            ? null
            : jsonEncode(memory.sourceEpisodeIds),
        ':accessCount': memory.accessCount,
        ':status': memory.status.name,
        ':supersededBy': memory.supersededBy,
        ':validAt': memory.validAt?.toUtc().toIso8601String(),
        ':invalidAt': memory.invalidAt?.toUtc().toIso8601String(),
      },
    );
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
      'UPDATE durable_memories SET ${sets.join(', ')} WHERE id = :id',
      parameters: params,
    );
  }

  /// Full-text search over active durable memories using BM25 ranking.
  Future<List<({StoredMemory memory, double score})>> searchMemories(
    String query, {
    int limit = 10,
  }) async {
    final sanitized = _sanitizeFtsQuery(query);
    final result = await _db.rawExecute(
      'SELECT m.*, bm25(${_durableMemoriesFts.tableName}) AS rank '
      'FROM durable_memories m '
      'JOIN ${_durableMemoriesFts.tableName} '
      'ON m.rowid = ${_durableMemoriesFts.tableName}.rowid '
      'WHERE ${_durableMemoriesFts.tableName} MATCH :query '
      "AND m.status = 'active' "
      'ORDER BY rank '
      'LIMIT :limit',
      parameters: {':query': sanitized, ':limit': limit},
    );

    return result.rows.map((row) {
      final score = -(row['rank'] as num).toDouble();
      return (memory: _rowToStoredMemory(row), score: score);
    }).toList();
  }

  /// Returns active memories ordered by importance (descending).
  Future<List<StoredMemory>> listActiveMemories({int limit = 200}) async {
    final result = await _db.rawExecute(
      "SELECT * FROM durable_memories WHERE status = 'active' "
      'ORDER BY importance DESC LIMIT :limit',
      parameters: {':limit': limit},
    );
    return result.rows.map(_rowToStoredMemory).toList();
  }

  /// Fetches memories by their IDs, preserving the given order.
  Future<List<StoredMemory>> findMemoriesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];

    final placeholders = <String>[];
    final params = <String, dynamic>{};
    for (var i = 0; i < ids.length; i++) {
      placeholders.add(':id$i');
      params[':id$i'] = ids[i];
    }

    final result = await _db.rawExecute(
      'SELECT * FROM durable_memories '
      'WHERE id IN (${placeholders.join(', ')})',
      parameters: params,
    );

    final byId = {
      for (final row in result.rows) row['id'] as String: _rowToStoredMemory(row),
    };
    return ids.where(byId.containsKey).map((id) => byId[id]!).toList();
  }

  /// Finds active memories associated with any of the given entity IDs.
  Future<List<StoredMemory>> findMemoriesByEntityIds(
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
      'SELECT DISTINCT m.* FROM durable_memories m, json_each(m.entity_ids) je '
      "WHERE je.value IN (${placeholders.join(', ')}) AND m.status = 'active'",
      parameters: params,
    );

    return result.rows.map(_rowToStoredMemory).toList();
  }

  /// Bumps access_count and last_accessed for memories.
  Future<void> updateAccessStats(List<String> ids) async {
    if (ids.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      await _db.rawExecute(
        'UPDATE durable_memories SET access_count = access_count + 1, '
        'last_accessed = :now WHERE id = :id',
        parameters: {':now': now, ':id': id},
      );
    }
  }

  /// Marks a memory as superseded by another.
  Future<void> supersede(String oldId, String newId) async {
    await _db.rawExecute(
      "UPDATE durable_memories SET status = 'superseded', "
      'superseded_by = :newId, '
      'updated_at = :now '
      'WHERE id = :oldId',
      parameters: {
        ':newId': newId,
        ':oldId': oldId,
        ':now': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  /// Returns the total number of active memories.
  Future<int> activeMemoryCount() async {
    final result = await _db.rawExecute(
      "SELECT COUNT(*) as cnt FROM durable_memories WHERE status = 'active'",
    );
    return result.rows.first['cnt'] as int;
  }

  // ── Importance decay ──────────────────────────────────────────────────

  /// Decays importance of active memories not accessed within
  /// [inactivePeriod]. Returns the number of memories affected.
  Future<int> applyImportanceDecay({
    required Duration inactivePeriod,
    required double decayRate,
  }) async {
    final cutoff =
        DateTime.now().subtract(inactivePeriod).toUtc().toIso8601String();
    final result = await _db.rawExecute(
      'UPDATE durable_memories SET importance = importance * :rate '
      "WHERE status = 'active' AND "
      '((last_accessed IS NOT NULL AND last_accessed < :cutoff) '
      'OR (last_accessed IS NULL AND updated_at < :cutoff))',
      parameters: {':rate': decayRate, ':cutoff': cutoff},
    );
    return result.affectedRows;
  }

  // ── Embedding operations ──────────────────────────────────────────────

  /// Stores an embedding vector for a memory as a BLOB.
  Future<void> updateMemoryEmbedding(
    String id,
    List<double> embedding,
  ) async {
    final blob = _embeddingToBlob(embedding);
    await _db.rawExecute(
      'UPDATE durable_memories SET embedding = :embedding WHERE id = :id',
      parameters: {':embedding': blob, ':id': id},
    );
  }

  /// Loads all active memories that have embeddings.
  Future<List<({String id, String content, List<double> embedding, DateTime updatedAt, double importance, int accessCount})>>
      loadMemoriesWithEmbeddings() async {
    final result = await _db.rawExecute(
      'SELECT id, content, embedding, updated_at, importance, access_count '
      "FROM durable_memories WHERE embedding IS NOT NULL AND status = 'active'",
    );

    return result.rows.map((row) {
      final blob = row['embedding'] as Uint8List;
      return (
        id: row['id'] as String,
        content: row['content'] as String,
        embedding: _blobToEmbedding(blob),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        importance: (row['importance'] as num).toDouble(),
        accessCount: (row['access_count'] as num).toInt(),
      );
    }).toList();
  }

  // ── Entity operations ─────────────────────────────────────────────────

  /// Inserts or replaces an entity (upsert by name).
  /// Returns the entity ID (existing or new).
  Future<String> upsertEntity({
    required String id,
    required String name,
    required String type,
  }) async {
    await _db.rawExecute(
      'INSERT OR REPLACE INTO durable_entities (id, name, type) '
      'VALUES (:id, :name, :type)',
      parameters: {':id': id, ':name': name, ':type': type},
    );
    return id;
  }

  /// Finds an entity by exact name match.
  Future<({String id, String name, String type})?> findEntityByName(
    String name,
  ) async {
    final result = await _db.rawExecute(
      'SELECT * FROM durable_entities WHERE name = :name',
      parameters: {':name': name},
    );
    if (result.isEmpty) return null;
    final row = result.rows.first;
    return (
      id: row['id'] as String,
      name: row['name'] as String,
      type: row['type'] as String,
    );
  }

  /// Finds entities whose names appear in the query text.
  /// Case-insensitive substring match.
  Future<List<({String id, String name, String type})>>
      findEntitiesByNameMatch(String query) async {
    final result = await _db.rawExecute(
      'SELECT * FROM durable_entities',
    );
    final lowerQuery = query.toLowerCase();
    return result.rows
        .where((row) =>
            lowerQuery.contains((row['name'] as String).toLowerCase()))
        .map((row) => (
              id: row['id'] as String,
              name: row['name'] as String,
              type: row['type'] as String,
            ))
        .toList();
  }

  // ── Relationship operations ───────────────────────────────────────────

  /// Inserts or replaces a relationship (upsert by composite PK).
  Future<void> upsertRelationship({
    required String fromEntity,
    required String toEntity,
    required String relation,
    required double confidence,
  }) async {
    await _db.rawExecute(
      'INSERT OR REPLACE INTO durable_relationships '
      '(from_entity, to_entity, relation, confidence, updated_at) '
      'VALUES (:from, :to, :rel, :conf, :updated)',
      parameters: {
        ':from': fromEntity,
        ':to': toEntity,
        ':rel': relation,
        ':conf': confidence,
        ':updated': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  /// Returns all relationships connected to [entityId] (either direction).
  Future<List<({String fromEntity, String toEntity, String relation, double confidence})>>
      findRelationshipsForEntity(String entityId) async {
    final result = await _db.rawExecute(
      'SELECT * FROM durable_relationships '
      'WHERE from_entity = :id OR to_entity = :id',
      parameters: {':id': entityId},
    );

    return result.rows
        .map((row) => (
              fromEntity: row['from_entity'] as String,
              toEntity: row['to_entity'] as String,
              relation: row['relation'] as String,
              confidence: (row['confidence'] as num).toDouble(),
            ))
        .toList();
  }

  // ── Internal helpers ──────────────────────────────────────────────────

  /// Converts a raw row to a [StoredMemory].
  static StoredMemory _rowToStoredMemory(Map<String, dynamic> row) {
    return StoredMemory(
      id: row['id'] as String,
      content: row['content'] as String,
      importance: (row['importance'] as num).toDouble(),
      entityIds: row['entity_ids'] != null
          ? (jsonDecode(row['entity_ids'] as String) as List).cast<String>()
          : [],
      sourceEpisodeIds: row['source_ids'] != null
          ? (jsonDecode(row['source_ids'] as String) as List).cast<String>()
          : [],
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      lastAccessed: row['last_accessed'] != null
          ? DateTime.parse(row['last_accessed'] as String)
          : null,
      accessCount: (row['access_count'] as num).toInt(),
      status: MemoryStatus.values.firstWhere(
        (s) => s.name == (row['status'] as String),
        orElse: () => MemoryStatus.active,
      ),
      supersededBy: row['superseded_by'] as String?,
      validAt: row['valid_at'] != null
          ? DateTime.parse(row['valid_at'] as String)
          : null,
      invalidAt: row['invalid_at'] != null
          ? DateTime.parse(row['invalid_at'] as String)
          : null,
    );
  }

  /// Sanitizes a raw text string for use in FTS5 MATCH queries.
  ///
  /// Uses OR logic so any matching token triggers a result. This is
  /// important for conflict detection during consolidation where the new
  /// and existing content may share only a few key terms.
  static String _sanitizeFtsQuery(String raw) {
    final tokens = raw
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return '""';
    return tokens.map((t) => '"$t"').join(' OR ');
  }

  static Uint8List _embeddingToBlob(List<double> embedding) {
    final float32 = Float32List.fromList(embedding);
    return float32.buffer.asUint8List();
  }

  static List<double> _blobToEmbedding(Uint8List blob) {
    final aligned = Float32List(blob.length ~/ 4);
    aligned.buffer.asUint8List().setAll(0, blob);
    return aligned.toList();
  }

  Future<void> _createFts5IfNeeded() async {
    final exists = await _fts5TableExists(_durableMemoriesFts.tableName);
    if (!exists) {
      await _db.rawExecute(SqliteDdl.createFts5Table(_durableMemoriesFts));
      for (final trigger
          in SqliteDdl.createFts5Triggers(_durableMemoriesFts)) {
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
