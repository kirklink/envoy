import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'stored_memory.dart';

/// Low-level SQLite operations for the durable memory component.
///
/// All tables use an optional [prefix] to support multi-agent isolation in a
/// shared database. Uses raw SQL via `sqlite3.Database` — no code gen.
class DurableMemoryStore {
  final sqlite3.Database _db;
  final String _prefix;

  /// The table name for durable memories (with prefix).
  String get _memories => '${_prefix}durable_memories';
  String get _memoriesFts => '${_prefix}durable_memories_fts';
  String get _entities => '${_prefix}durable_entities';
  String get _relationships => '${_prefix}durable_relationships';

  DurableMemoryStore(this._db, {String prefix = ''}) : _prefix = prefix;

  // ── Initialization ──────────────────────────────────────────────────────

  /// Creates all tables and FTS5 indexes. Idempotent.
  void initialize() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_memories (
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

    _createFts5IfNeeded();

    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_entities (
        id    TEXT PRIMARY KEY,
        name  TEXT NOT NULL UNIQUE,
        type  TEXT NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_relationships (
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
  void insertMemory(StoredMemory memory) {
    _db.execute(
      'INSERT INTO $_memories '
      '(id, content, entity_ids, importance, created_at, updated_at, '
      'source_ids, access_count, status, superseded_by, valid_at, invalid_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        memory.id,
        memory.content,
        memory.entityIds.isEmpty ? null : jsonEncode(memory.entityIds),
        memory.importance,
        memory.createdAt.toUtc().toIso8601String(),
        memory.updatedAt.toUtc().toIso8601String(),
        memory.sourceEpisodeIds.isEmpty
            ? null
            : jsonEncode(memory.sourceEpisodeIds),
        memory.accessCount,
        memory.status.name,
        memory.supersededBy,
        memory.validAt?.toUtc().toIso8601String(),
        memory.invalidAt?.toUtc().toIso8601String(),
      ],
    );
  }

  /// Partially updates a memory. Only non-null fields are updated.
  void updateMemory(
    String id, {
    String? content,
    double? importance,
    List<String>? entityIds,
    List<String>? sourceIds,
  }) {
    final sets = <String>[];
    final params = <Object?>[];

    if (content != null) {
      sets.add('content = ?');
      params.add(content);
    }
    if (importance != null) {
      sets.add('importance = ?');
      params.add(importance);
    }
    if (entityIds != null) {
      sets.add('entity_ids = ?');
      params.add(jsonEncode(entityIds));
    }
    if (sourceIds != null) {
      sets.add('source_ids = ?');
      params.add(jsonEncode(sourceIds));
    }

    // Always bump updated_at.
    sets.add('updated_at = ?');
    params.add(DateTime.now().toUtc().toIso8601String());

    if (sets.isEmpty) return;

    params.add(id);
    _db.execute(
      'UPDATE $_memories SET ${sets.join(', ')} WHERE id = ?',
      params,
    );
  }

  /// Full-text search over active durable memories using BM25 ranking.
  List<({StoredMemory memory, double score})> searchMemories(
    String query, {
    int limit = 10,
  }) {
    final sanitized = _sanitizeFtsQuery(query);
    final result = _db.select(
      'SELECT m.*, bm25($_memoriesFts) AS rank '
      'FROM $_memories m '
      'JOIN $_memoriesFts ON m.rowid = $_memoriesFts.rowid '
      'WHERE $_memoriesFts MATCH ? '
      "AND m.status = 'active' "
      'ORDER BY rank '
      'LIMIT ?',
      [sanitized, limit],
    );

    return result.map((row) {
      final m = Map<String, dynamic>.of(row);
      final score = -(m.remove('rank') as num).toDouble();
      return (memory: _rowToStoredMemory(m), score: score);
    }).toList();
  }

  /// Returns active memories ordered by importance (descending).
  List<StoredMemory> listActiveMemories({int limit = 200}) {
    final result = _db.select(
      "SELECT * FROM $_memories WHERE status = 'active' "
      'ORDER BY importance DESC LIMIT ?',
      [limit],
    );
    return result.map((row) => _rowToStoredMemory(Map.of(row))).toList();
  }

  /// Fetches memories by their IDs, preserving the given order.
  List<StoredMemory> findMemoriesByIds(List<String> ids) {
    if (ids.isEmpty) return [];

    final placeholders = List.filled(ids.length, '?').join(', ');
    final result = _db.select(
      'SELECT * FROM $_memories WHERE id IN ($placeholders)',
      ids,
    );

    final byId = {
      for (final row in result)
        row['id'] as String: _rowToStoredMemory(Map.of(row)),
    };
    return ids.where(byId.containsKey).map((id) => byId[id]!).toList();
  }

  /// Finds active memories associated with any of the given entity IDs.
  List<StoredMemory> findMemoriesByEntityIds(List<String> entityIds) {
    if (entityIds.isEmpty) return [];

    final placeholders = List.filled(entityIds.length, '?').join(', ');
    final result = _db.select(
      'SELECT DISTINCT m.* FROM $_memories m, json_each(m.entity_ids) je '
      "WHERE je.value IN ($placeholders) AND m.status = 'active'",
      entityIds,
    );

    return result.map((row) => _rowToStoredMemory(Map.of(row))).toList();
  }

  /// Bumps access_count and last_accessed for memories.
  void updateAccessStats(List<String> ids) {
    if (ids.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      _db.execute(
        'UPDATE $_memories SET access_count = access_count + 1, '
        'last_accessed = ? WHERE id = ?',
        [now, id],
      );
    }
  }

  /// Marks a memory as superseded by another.
  void supersede(String oldId, String newId) {
    _db.execute(
      "UPDATE $_memories SET status = 'superseded', "
      'superseded_by = ?, '
      'updated_at = ? '
      'WHERE id = ?',
      [newId, DateTime.now().toUtc().toIso8601String(), oldId],
    );
  }

  /// Returns the total number of active memories.
  int activeMemoryCount() {
    final result = _db.select(
      "SELECT COUNT(*) as cnt FROM $_memories WHERE status = 'active'",
    );
    return result.first['cnt'] as int;
  }

  // ── Importance decay ──────────────────────────────────────────────────

  /// Decays importance of active memories not accessed within
  /// [inactivePeriod]. Returns the number of memories affected.
  int applyImportanceDecay({
    required Duration inactivePeriod,
    required double decayRate,
  }) {
    final cutoff =
        DateTime.now().subtract(inactivePeriod).toUtc().toIso8601String();
    _db.execute(
      'UPDATE $_memories SET importance = importance * ? '
      "WHERE status = 'active' AND "
      '((last_accessed IS NOT NULL AND last_accessed < ?) '
      'OR (last_accessed IS NULL AND updated_at < ?))',
      [decayRate, cutoff, cutoff],
    );
    return _db.updatedRows;
  }

  // ── Embedding operations ──────────────────────────────────────────────

  /// Stores an embedding vector for a memory as a BLOB.
  void updateMemoryEmbedding(String id, List<double> embedding) {
    final blob = _embeddingToBlob(embedding);
    _db.execute(
      'UPDATE $_memories SET embedding = ? WHERE id = ?',
      [blob, id],
    );
  }

  /// Loads all active memories that have embeddings.
  List<
      ({
        String id,
        String content,
        List<double> embedding,
        DateTime updatedAt,
        double importance,
        int accessCount,
      })> loadMemoriesWithEmbeddings() {
    final result = _db.select(
      'SELECT id, content, embedding, updated_at, importance, access_count '
      "FROM $_memories WHERE embedding IS NOT NULL AND status = 'active'",
    );

    return result.map((row) {
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
  String upsertEntity({
    required String id,
    required String name,
    required String type,
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO $_entities (id, name, type) '
      'VALUES (?, ?, ?)',
      [id, name, type],
    );
    return id;
  }

  /// Finds an entity by exact name match.
  ({String id, String name, String type})? findEntityByName(String name) {
    final result = _db.select(
      'SELECT * FROM $_entities WHERE name = ?',
      [name],
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return (
      id: row['id'] as String,
      name: row['name'] as String,
      type: row['type'] as String,
    );
  }

  /// Finds entities whose names appear in the query text.
  /// Case-insensitive substring match.
  List<({String id, String name, String type})> findEntitiesByNameMatch(
    String query,
  ) {
    final result = _db.select('SELECT * FROM $_entities');
    final lowerQuery = query.toLowerCase();
    return result
        .where(
            (row) => lowerQuery.contains((row['name'] as String).toLowerCase()))
        .map((row) => (
              id: row['id'] as String,
              name: row['name'] as String,
              type: row['type'] as String,
            ))
        .toList();
  }

  // ── Relationship operations ───────────────────────────────────────────

  /// Inserts or replaces a relationship (upsert by composite PK).
  void upsertRelationship({
    required String fromEntity,
    required String toEntity,
    required String relation,
    required double confidence,
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO $_relationships '
      '(from_entity, to_entity, relation, confidence, updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        fromEntity,
        toEntity,
        relation,
        confidence,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  /// Returns all relationships connected to [entityId] (either direction).
  List<
      ({
        String fromEntity,
        String toEntity,
        String relation,
        double confidence,
      })> findRelationshipsForEntity(String entityId) {
    final result = _db.select(
      'SELECT * FROM $_relationships '
      'WHERE from_entity = ? OR to_entity = ?',
      [entityId, entityId],
    );

    return result
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

  void _createFts5IfNeeded() {
    final result = _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [_memoriesFts],
    );
    if (result.isEmpty) {
      _db.execute(
        'CREATE VIRTUAL TABLE $_memoriesFts USING fts5('
        'content, '
        "content='$_memories', "
        "content_rowid='rowid', "
        'tokenize="porter unicode61"'
        ')',
      );

      // Insert trigger.
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${_memories}_ai AFTER INSERT ON $_memories BEGIN
          INSERT INTO $_memoriesFts(rowid, content)
          VALUES (new.rowid, new.content);
        END
      ''');

      // Delete trigger.
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${_memories}_ad AFTER DELETE ON $_memories BEGIN
          INSERT INTO $_memoriesFts($_memoriesFts, rowid, content)
          VALUES('delete', old.rowid, old.content);
        END
      ''');

      // Update trigger.
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${_memories}_au AFTER UPDATE ON $_memories BEGIN
          INSERT INTO $_memoriesFts($_memoriesFts, rowid, content)
          VALUES('delete', old.rowid, old.content);
          INSERT INTO $_memoriesFts(rowid, content)
          VALUES (new.rowid, new.content);
        END
      ''');
    }
  }
}
