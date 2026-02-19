import 'dart:convert';
import 'dart:math';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:stanza/stanza.dart';

import '../dynamic_tool.dart';
import 'stanza_entities.dart';

/// Stanza-backed persistence for Envoy — tool registry and session history.
///
/// ## Setup
///
/// ```dart
/// final storage = StanzaEnvoyStorage(Stanza.url('postgresql://...'));
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
  final Stanza _stanza;

  /// Tracks the next sort_order value for a given session.
  /// Initialized from the DB message count when a session is loaded.
  int _nextSortOrder = 0;

  StanzaEnvoyStorage(this._stanza);

  // ── Schema ──────────────────────────────────────────────────────────────────

  /// Creates the three Envoy tables if they do not already exist.
  ///
  /// Safe to call on every startup — uses `CREATE TABLE IF NOT EXISTS`.
  Future<void> initialize() async {
    await _stanza.rawExecute('''
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

    await _stanza.rawExecute('''
      CREATE TABLE IF NOT EXISTS envoy_sessions (
        id         TEXT PRIMARY KEY,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await _stanza.rawExecute('''
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
    final result = await _stanza.execute<ToolRecordEntity>(
      SelectQuery(ToolRecordEntity.$table)..selectStar(),
    );
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
    final entity = ToolRecordEntity()
      ..name = tool.name
      ..description = tool.description
      ..permission = tool.permission.name
      ..scriptPath = tool.scriptPath
      ..inputSchema = jsonEncode(tool.inputSchema)
      ..createdAt = DateTime.now().toUtc();

    await _stanza.execute(
      InsertQuery(ToolRecordEntity.$table)
        ..insertEntity<ToolRecordEntity>(entity)
        ..onConflict(
          target: [ToolRecordEntity.$table.name],
          doUpdate: (set) => set
            ..column(ToolRecordEntity.$table.description).string(entity.description)
            ..column(ToolRecordEntity.$table.permission).string(entity.permission)
            ..column(ToolRecordEntity.$table.scriptPath).string(entity.scriptPath)
            ..column(ToolRecordEntity.$table.inputSchema).string(entity.inputSchema),
        ),
    );
  }

  /// Searches the tool registry for tools whose name or description matches
  /// [query] using PostgreSQL full-text search.
  ///
  /// Returns an empty list when no tools match or the registry is empty.
  Future<List<Map<String, String>>> searchTools(String query) async {
    final t = ToolRecordEntity.$table;
    final result = await _stanza.execute<ToolRecordEntity>(
      SelectQuery(t)
        ..selectStar()
        ..where(t.name).fullTextMatches(query)
        ..or(t.description).fullTextMatches(query),
    );
    return result.entities
        .map((e) => {
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
      final result = await _stanza.execute<SessionEntity>(
        SelectQuery(SessionEntity.$table)
          ..selectStar()
          ..where(SessionEntity.$table.id).matches(sessionId, caseSensitive: true),
      );
      if (result.isNotEmpty) {
        _nextSortOrder = await _messageCount(sessionId);
        return sessionId;
      }
    }

    final id = sessionId ?? _generateId();
    final entity = SessionEntity()
      ..id = id
      ..createdAt = DateTime.now().toUtc();

    await _stanza.execute(
      InsertQuery(SessionEntity.$table)..insertEntity<SessionEntity>(entity),
    );
    _nextSortOrder = 0;
    return id;
  }

  // ── Messages ────────────────────────────────────────────────────────────────

  /// Loads all messages for [sessionId] in conversation order.
  Future<List<anthropic.Message>> loadMessages(String sessionId) async {
    final result = await _stanza.execute<MessageEntity>(
      SelectQuery(MessageEntity.$table)
        ..selectStar()
        ..where(MessageEntity.$table.sessionId)
            .matches(sessionId, caseSensitive: true)
        ..orderBy(MessageEntity.$table.sortOrder),
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
    final entity = MessageEntity()
      ..sessionId = sessionId
      ..content = jsonEncode(message.toJson())
      ..sortOrder = _nextSortOrder++
      ..createdAt = DateTime.now().toUtc();

    await _stanza.execute(
      InsertQuery(MessageEntity.$table)..insertEntity<MessageEntity>(entity),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<int> _messageCount(String sessionId) async {
    final result = await _stanza.execute<MessageEntity>(
      SelectQuery(MessageEntity.$table)
        ..selectFields([MessageEntity.$table.id.count().rename('cnt')])
        ..where(MessageEntity.$table.sessionId)
            .matches(sessionId, caseSensitive: true),
    );
    return result.aggregates.firstOrNull?['cnt'] as int? ?? 0;
  }

  static String _generateId() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
