import 'dart:convert';
import 'dart:math';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:stanza/stanza.dart';

import '../dynamic_tool.dart';
import 'stanza_entities.dart';

/// Table descriptors — instantiated once and reused across queries.
final _tools = $ToolRecordEntityTable();
final _sessions = $SessionEntityTable();
final _messages = $MessageEntityTable();

/// Stanza-backed persistence for Envoy — tool registry and session history.
///
/// ## Setup
///
/// ```dart
/// final storage = StanzaEnvoyStorage(db); // db is a DatabaseAdapter
/// await storage.initialize();           // creates tables once
///
/// final sessionId = await storage.ensureSession();   // new session
/// // or: await storage.ensureSession('existing-id'); // restore session
///
/// final context = EnvoyContext(
///   messages: await storage.loadMessages(sessionId),
///   onMessage: (msg) => storage.appendMessage(sessionId, msg),
/// );
///
/// final agent = EnvoyAgent(config, context: context, tools: [...]);
///
/// // Restore previously registered dynamic tools:
/// for (final tool in await storage.loadTools()) {
///   agent.registerTool(tool);
/// }
///
/// // When registering new dynamic tools, also persist them:
/// agent.registerTool(RegisterToolTool(
///   workspaceRoot,
///   onRegister: (tool) {
///     agent.registerTool(tool);
///     if (tool is DynamicTool) storage.saveTool(tool);
///   },
/// ));
/// ```
class StanzaEnvoyStorage {
  final DatabaseAdapter _db;

  /// Tracks the next sort_order value for a given session.
  /// Initialized from the DB message count when a session is loaded.
  int _nextSortOrder = 0;

  StanzaEnvoyStorage(this._db);

  // ── Schema ──────────────────────────────────────────────────────────────────

  /// Creates the three Envoy tables if they do not already exist.
  ///
  /// Safe to call on every startup — uses `CREATE TABLE IF NOT EXISTS`.
  Future<void> initialize() async {
    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS envoy_tools (
        id          SERIAL PRIMARY KEY,
        name        TEXT NOT NULL UNIQUE,
        description TEXT NOT NULL,
        permission  TEXT NOT NULL,
        script_path TEXT NOT NULL,
        input_schema TEXT NOT NULL,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS envoy_sessions (
        id         TEXT PRIMARY KEY,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await _db.rawExecute('''
      CREATE TABLE IF NOT EXISTS envoy_messages (
        id         SERIAL PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES envoy_sessions(id) ON DELETE CASCADE,
        content    TEXT NOT NULL,
        sort_order INT  NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
  }

  // ── Tool registry ───────────────────────────────────────────────────────────

  /// Loads all persisted dynamic tools from the registry.
  Future<List<DynamicTool>> loadTools() async {
    final result = await _db.execute(SelectQuery(_tools));
    return result.entities.map((e) => DynamicTool.fromMap({
          'name': e.name,
          'description': e.description,
          'permission': e.permission,
          'scriptPath': e.scriptPath,
          'inputSchema': e.inputSchema,
        })).toList();
  }

  /// Persists a dynamic tool, replacing an existing record with the same name.
  Future<void> saveTool(DynamicTool tool) async {
    final row = ToolRecordEntityInsert(
      name: tool.name,
      description: tool.description,
      permission: tool.permission.name,
      scriptPath: tool.scriptPath,
      inputSchema: jsonEncode(tool.inputSchema),
    ).toRow();

    await _db.execute(
      InsertQuery(_tools)
        .values(row)
        .onConflict(
          target: [_tools.name],
          doUpdate: {
            'description': tool.description,
            'permission': tool.permission.name,
            'script_path': tool.scriptPath,
            'input_schema': jsonEncode(tool.inputSchema),
          },
        ),
    );
  }

  /// Searches the tool registry for tools whose name or description matches
  /// [query] using PostgreSQL full-text search.
  ///
  /// Returns an empty list when no tools match or the registry is empty.
  Future<List<Map<String, String>>> searchTools(String query) async {
    final result = await _db.execute(
      SelectQuery(_tools)
        .where((t) => t.name.fullTextMatches(query) |
                      t.description.fullTextMatches(query)),
    );
    return result.entities
        .map((e) => <String, String>{
              'name': e.name,
              'description': e.description,
              'permission': e.permission,
            })
        .toList();
  }

  // ── Sessions ────────────────────────────────────────────────────────────────

  /// Returns [sessionId] if it already exists, or creates a new session.
  ///
  /// Pass a previously returned session ID to restore an existing conversation.
  /// Omit (or pass `null`) to start a fresh session.
  Future<String> ensureSession([String? sessionId]) async {
    if (sessionId != null) {
      final result = await _db.execute(
        SelectQuery(_sessions)
          .where((t) => t.id.equals(sessionId)),
      );
      if (result.isNotEmpty) {
        _nextSortOrder = await _messageCount(sessionId);
        return sessionId;
      }
    }

    final id = sessionId ?? _generateId();
    await _db.execute(
      InsertQuery(_sessions)
        .values(SessionEntityInsert(id: id).toRow()),
    );
    _nextSortOrder = 0;
    return id;
  }

  // ── Messages ────────────────────────────────────────────────────────────────

  /// Loads all messages for [sessionId] in conversation order.
  Future<List<anthropic.Message>> loadMessages(String sessionId) async {
    final result = await _db.execute(
      SelectQuery(_messages)
        .where((t) => t.sessionId.equals(sessionId))
        .orderBy((t) => t.sortOrder.asc()),
    );
    return result.entities.map((e) {
      final json = jsonDecode(e.content) as Map<String, dynamic>;
      return anthropic.Message.fromJson(json);
    }).toList();
  }

  /// Appends [message] to [sessionId]'s history.
  ///
  /// Called automatically via [EnvoyContext.onMessage] — no need to call
  /// this directly when the context is wired up correctly.
  Future<void> appendMessage(
    String sessionId,
    anthropic.Message message,
  ) async {
    await _db.execute(
      InsertQuery(_messages).values(
        MessageEntityInsert(
          sessionId: sessionId,
          content: jsonEncode(message.toJson()),
          sortOrder: _nextSortOrder++,
        ).toRow(),
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<int> _messageCount(String sessionId) async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM envoy_messages WHERE session_id = @p0',
      parameters: {'p0': sessionId},
      mapper: (row) => row['cnt'] as int,
    );
    return result.firstOrNull ?? 0;
  }

  static String _generateId() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
