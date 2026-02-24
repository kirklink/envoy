import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'memory_store.dart';
import 'stored_memory.dart';

/// SQLite-backed implementation of [MemoryStore].
///
/// Uses a single `memories` table with FTS5 for full-text search, plus
/// entity graph tables. All table names are prefixed with [prefix] to
/// support multi-agent isolation in a shared database.
class SqliteMemoryStore implements MemoryStore {
  final sqlite3.Database _db;
  final String _prefix;

  String get _memories => '${_prefix}memories';
  String get _memoriesFts => '${_prefix}memories_fts';
  String get _entities => '${_prefix}entities';
  String get _relationships => '${_prefix}relationships';

  /// Creates a SQLite memory store.
  ///
  /// [db] is a raw sqlite3 database (e.g., from `sqlite3.openInMemory()`
  /// or from `cellar.database`). [prefix] is prepended to all table names
  /// for multi-agent isolation.
  SqliteMemoryStore(this._db, {String prefix = ''}) : _prefix = prefix;

  @override
  Future<void> initialize() async {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_memories (
        id             TEXT PRIMARY KEY,
        content        TEXT NOT NULL,
        component      TEXT NOT NULL,
        category       TEXT NOT NULL,
        importance     REAL NOT NULL DEFAULT 0.5,
        session_id     TEXT,
        source_ids     TEXT,
        entity_ids     TEXT,
        embedding      BLOB,
        created_at     TEXT NOT NULL,
        updated_at     TEXT NOT NULL,
        last_accessed  TEXT,
        access_count   INTEGER NOT NULL DEFAULT 0,
        status         TEXT NOT NULL DEFAULT 'active',
        valid_at       TEXT,
        invalid_at     TEXT,
        superseded_by  TEXT
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

  void _createFts5IfNeeded() {
    final result = _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [_memoriesFts],
    );
    if (result.isEmpty) {
      _db.execute('''
        CREATE VIRTUAL TABLE $_memoriesFts USING fts5(
          content,
          content='$_memories',
          content_rowid='rowid'
        )
      ''');

      // Triggers to keep FTS5 in sync.
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${_prefix}memories_ai AFTER INSERT ON $_memories BEGIN
          INSERT INTO $_memoriesFts(rowid, content) VALUES (new.rowid, new.content);
        END
      ''');
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${_prefix}memories_ad AFTER DELETE ON $_memories BEGIN
          INSERT INTO $_memoriesFts($_memoriesFts, rowid, content) VALUES ('delete', old.rowid, old.content);
        END
      ''');
      _db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${_prefix}memories_au AFTER UPDATE OF content ON $_memories BEGIN
          INSERT INTO $_memoriesFts($_memoriesFts, rowid, content) VALUES ('delete', old.rowid, old.content);
          INSERT INTO $_memoriesFts(rowid, content) VALUES (new.rowid, new.content);
        END
      ''');
    }
  }

  @override
  Future<void> insert(StoredMemory memory) async {
    _db.execute(
      'INSERT INTO $_memories '
      '(id, content, component, category, importance, session_id, '
      'source_ids, entity_ids, embedding, created_at, updated_at, '
      'last_accessed, access_count, status, valid_at, invalid_at, '
      'superseded_by) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        memory.id,
        memory.content,
        memory.component,
        memory.category,
        memory.importance,
        memory.sessionId,
        memory.sourceEpisodeIds.isEmpty
            ? null
            : jsonEncode(memory.sourceEpisodeIds),
        memory.entityIds.isEmpty ? null : jsonEncode(memory.entityIds),
        memory.embedding != null ? _embeddingToBlob(memory.embedding!) : null,
        memory.createdAt.toUtc().toIso8601String(),
        memory.updatedAt.toUtc().toIso8601String(),
        memory.lastAccessed?.toUtc().toIso8601String(),
        memory.accessCount,
        memory.status.name,
        memory.validAt?.toUtc().toIso8601String(),
        memory.invalidAt?.toUtc().toIso8601String(),
        memory.supersededBy,
      ],
    );
  }

  @override
  Future<void> update(
    String id, {
    String? content,
    double? importance,
    List<String>? entityIds,
    List<double>? embedding,
    String? status,
    String? supersededBy,
    DateTime? invalidAt,
    List<String>? sourceEpisodeIds,
  }) async {
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
    if (embedding != null) {
      sets.add('embedding = ?');
      params.add(_embeddingToBlob(embedding));
    }
    if (status != null) {
      sets.add('status = ?');
      params.add(status);
    }
    if (supersededBy != null) {
      sets.add('superseded_by = ?');
      params.add(supersededBy);
    }
    if (invalidAt != null) {
      sets.add('invalid_at = ?');
      params.add(invalidAt.toUtc().toIso8601String());
    }
    if (sourceEpisodeIds != null) {
      sets.add('source_ids = ?');
      params.add(jsonEncode(sourceEpisodeIds));
    }

    // Always bump updated_at.
    sets.add('updated_at = ?');
    params.add(DateTime.now().toUtc().toIso8601String());

    if (sets.length == 1) return; // Only updated_at, skip.

    params.add(id);
    _db.execute(
      'UPDATE $_memories SET ${sets.join(', ')} WHERE id = ?',
      params,
    );
  }

  @override
  Future<List<StoredMemory>> findSimilar(
    String content,
    String component, {
    String? category,
    String? sessionId,
    int limit = 5,
  }) async {
    final sanitized = _sanitizeFtsQuery(content);
    if (sanitized.isEmpty) return [];

    final filters = <String>["m.status = 'active'", 'm.component = ?'];
    final params = <Object?>[sanitized, component];

    if (category != null) {
      filters.add('m.category = ?');
      params.add(category);
    }
    if (sessionId != null) {
      filters.add('m.session_id = ?');
      params.add(sessionId);
    }

    params.add(limit);

    final result = _db.select(
      'SELECT m.*, bm25($_memoriesFts) AS rank '
      'FROM $_memories m '
      'JOIN $_memoriesFts ON m.rowid = $_memoriesFts.rowid '
      'WHERE $_memoriesFts MATCH ? AND ${filters.join(' AND ')} '
      'ORDER BY rank '
      'LIMIT ?',
      params,
    );

    return result.map((row) => _rowToStoredMemory(Map.of(row))).toList();
  }

  @override
  Future<List<FtsMatch>> searchFts(String query, {int limit = 50}) async {
    final sanitized = _sanitizeFtsQuery(query);
    if (sanitized.isEmpty) return [];

    final now = DateTime.now().toUtc().toIso8601String();
    final result = _db.select(
      'SELECT m.*, bm25($_memoriesFts) AS rank '
      'FROM $_memories m '
      'JOIN $_memoriesFts ON m.rowid = $_memoriesFts.rowid '
      'WHERE $_memoriesFts MATCH ? '
      "AND m.status = 'active' "
      'AND (m.invalid_at IS NULL OR m.invalid_at > ?) '
      'ORDER BY rank '
      'LIMIT ?',
      [sanitized, now, limit],
    );

    return result.map((row) {
      final m = Map<String, dynamic>.of(row);
      final score = -(m.remove('rank') as num).toDouble();
      return FtsMatch(memory: _rowToStoredMemory(m), score: score);
    }).toList();
  }

  @override
  Future<List<StoredMemory>> loadActiveWithEmbeddings() async {
    final now = DateTime.now().toUtc().toIso8601String();
    final result = _db.select(
      'SELECT * FROM $_memories '
      "WHERE status = 'active' "
      'AND embedding IS NOT NULL '
      'AND (invalid_at IS NULL OR invalid_at > ?)',
      [now],
    );
    return result.map((row) => _rowToStoredMemory(Map.of(row))).toList();
  }

  @override
  Future<List<StoredMemory>> findUnembeddedMemories({int limit = 100}) async {
    final result = _db.select(
      'SELECT * FROM $_memories '
      "WHERE status = 'active' AND embedding IS NULL "
      'LIMIT ?',
      [limit],
    );
    return result.map((row) => _rowToStoredMemory(Map.of(row))).toList();
  }

  // ── Entity graph ──────────────────────────────────────────────────────

  @override
  Future<void> upsertEntity(Entity entity) async {
    _db.execute(
      'INSERT INTO $_entities (id, name, type) VALUES (?, ?, ?) '
      'ON CONFLICT(name) DO UPDATE SET type = excluded.type',
      [entity.id, entity.name, entity.type],
    );
  }

  @override
  Future<void> upsertRelationship(Relationship rel) async {
    _db.execute(
      'INSERT INTO $_relationships (from_entity, to_entity, relation, '
      'confidence, updated_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(from_entity, to_entity, relation) DO UPDATE SET '
      'confidence = excluded.confidence, updated_at = excluded.updated_at',
      [
        rel.fromEntity,
        rel.toEntity,
        rel.relation,
        rel.confidence,
        rel.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<List<Entity>> findEntitiesByName(String query) async {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2)
        .toList();
    if (words.isEmpty) return [];

    // Match any word as a substring of entity name.
    final conditions = words.map((_) => 'LOWER(name) LIKE ?').join(' OR ');
    final params = words.map((w) => '%$w%').toList();

    final result = _db.select(
      'SELECT * FROM $_entities WHERE $conditions',
      params,
    );

    return result
        .map(
          (row) => Entity(
            id: row['id'] as String,
            name: row['name'] as String,
            type: row['type'] as String,
          ),
        )
        .toList();
  }

  @override
  Future<List<Relationship>> findRelationshipsForEntity(
    String entityId,
  ) async {
    final result = _db.select(
      'SELECT * FROM $_relationships '
      'WHERE from_entity = ? OR to_entity = ?',
      [entityId, entityId],
    );

    return result
        .map(
          (row) => Relationship(
            fromEntity: row['from_entity'] as String,
            toEntity: row['to_entity'] as String,
            relation: row['relation'] as String,
            confidence: (row['confidence'] as num).toDouble(),
            updatedAt: DateTime.parse(row['updated_at'] as String),
          ),
        )
        .toList();
  }

  @override
  Future<List<StoredMemory>> findMemoriesByEntityIds(
    List<String> entityIds,
  ) async {
    if (entityIds.isEmpty) return [];

    final placeholders = List.filled(entityIds.length, '?').join(', ');
    final result = _db.select(
      'SELECT DISTINCT m.* FROM $_memories m, json_each(m.entity_ids) je '
      "WHERE je.value IN ($placeholders) AND m.status = 'active'",
      entityIds,
    );

    return result.map((row) => _rowToStoredMemory(Map.of(row))).toList();
  }

  // ── Lifecycle operations ──────────────────────────────────────────────

  @override
  Future<void> updateAccessStats(List<String> ids) async {
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

  @override
  Future<int> applyImportanceDecay({
    required String component,
    required Duration inactivePeriod,
    required double decayRate,
    double? floorThreshold,
  }) async {
    final cutoff =
        DateTime.now().subtract(inactivePeriod).toUtc().toIso8601String();
    var floored = 0;

    if (floorThreshold != null) {
      // First, mark items that will drop below floor.
      _db.execute(
        'UPDATE $_memories SET status = \'decayed\' '
        "WHERE status = 'active' AND component = ? "
        'AND importance * ? < ? '
        'AND ((last_accessed IS NOT NULL AND last_accessed < ?) '
        'OR (last_accessed IS NULL AND updated_at < ?))',
        [component, decayRate, floorThreshold, cutoff, cutoff],
      );
      floored = _db.updatedRows;
    }

    // Then decay remaining active items.
    _db.execute(
      'UPDATE $_memories SET importance = importance * ? '
      "WHERE status = 'active' AND component = ? "
      'AND ((last_accessed IS NOT NULL AND last_accessed < ?) '
      'OR (last_accessed IS NULL AND updated_at < ?))',
      [decayRate, component, cutoff, cutoff],
    );

    return floored;
  }

  @override
  Future<int> expireSession(String sessionId, String component) async {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      'UPDATE $_memories SET status = \'expired\', invalid_at = ? '
      "WHERE status = 'active' AND session_id = ? AND component = ?",
      [now, sessionId, component],
    );
    return _db.updatedRows;
  }

  @override
  Future<void> expireItem(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      'UPDATE $_memories SET status = \'expired\', invalid_at = ? '
      'WHERE id = ?',
      [now, id],
    );
  }

  @override
  Future<void> supersede(String oldId, String newId) async {
    _db.execute(
      'UPDATE $_memories SET status = \'superseded\', '
      'superseded_by = ?, updated_at = ? WHERE id = ?',
      [newId, DateTime.now().toUtc().toIso8601String(), oldId],
    );
  }

  @override
  Future<int> activeItemCount(String component, {String? sessionId}) async {
    final filters = <String>["status = 'active'", 'component = ?'];
    final params = <Object?>[component];

    if (sessionId != null) {
      filters.add('session_id = ?');
      params.add(sessionId);
    }

    final result = _db.select(
      'SELECT COUNT(*) as cnt FROM $_memories '
      'WHERE ${filters.join(' AND ')}',
      params,
    );
    return result.first['cnt'] as int;
  }

  @override
  Future<List<StoredMemory>> activeItemsForSession(
    String sessionId,
    String component,
  ) async {
    final result = _db.select(
      'SELECT * FROM $_memories '
      "WHERE status = 'active' AND session_id = ? AND component = ?",
      [sessionId, component],
    );
    return result.map((row) => _rowToStoredMemory(Map.of(row))).toList();
  }

  @override
  Future<void> close() async {
    // Don't close the database — we don't own it.
  }

  // ── Private helpers ───────────────────────────────────────────────────

  StoredMemory _rowToStoredMemory(Map<String, dynamic> row) {
    // Remove rank if present (from FTS queries).
    row.remove('rank');

    return StoredMemory(
      id: row['id'] as String,
      content: row['content'] as String,
      component: row['component'] as String,
      category: row['category'] as String,
      importance: (row['importance'] as num).toDouble(),
      sessionId: row['session_id'] as String?,
      sourceEpisodeIds: _parseJsonList(row['source_ids']),
      entityIds: _parseJsonList(row['entity_ids']),
      embedding: _blobToEmbedding(row['embedding']),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      lastAccessed: row['last_accessed'] != null
          ? DateTime.parse(row['last_accessed'] as String)
          : null,
      accessCount: row['access_count'] as int,
      status: MemoryStatus.values.firstWhere(
        (s) => s.name == row['status'],
      ),
      validAt: row['valid_at'] != null
          ? DateTime.parse(row['valid_at'] as String)
          : null,
      invalidAt: row['invalid_at'] != null
          ? DateTime.parse(row['invalid_at'] as String)
          : null,
      supersededBy: row['superseded_by'] as String?,
    );
  }

  static List<String> _parseJsonList(Object? value) {
    if (value == null || value is! String) return [];
    final decoded = jsonDecode(value);
    if (decoded is! List) return [];
    return decoded.cast<String>();
  }

  static Uint8List _embeddingToBlob(List<double> embedding) {
    final floats = Float32List.fromList(embedding);
    return floats.buffer.asUint8List();
  }

  static List<double>? _blobToEmbedding(Object? value) {
    if (value == null || value is! Uint8List) return null;
    return value.buffer.asFloat32List().toList();
  }

  /// Sanitizes an FTS5 query to prevent syntax errors.
  static String _sanitizeFtsQuery(String query) {
    // Remove FTS5 operators and special characters.
    final cleaned = query
        .replaceAll(RegExp(r'[*"()]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '';

    // Split into words, filter short ones, join with OR for broad matching.
    final words = cleaned
        .split(' ')
        .where((w) => w.length > 1 && !_ftsReserved.contains(w.toUpperCase()))
        .toList();
    if (words.isEmpty) return '';

    return words.join(' OR ');
  }

  static const _ftsReserved = {'AND', 'OR', 'NOT', 'NEAR'};
}
