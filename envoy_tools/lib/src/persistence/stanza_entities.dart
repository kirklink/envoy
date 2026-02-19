import 'package:stanza/annotations.dart';

part 'stanza_entities.g.dart';

// ── Tool registry ─────────────────────────────────────────────────────────────

/// Persisted record of a dynamically registered tool.
@StanzaEntity(name: 'envoy_tools', snakeCase: true)
class ToolRecordEntity {
  @StanzaField(readOnly: true)
  late int id;

  /// Unique tool name (snake_case).
  late String name;

  late String description;

  /// ToolPermission.name (compute, readFile, writeFile, network, process).
  late String permission;

  /// Absolute path to the Dart script on disk.
  late String scriptPath;

  /// JSON-encoded inputSchema map.
  late String inputSchema;

  late DateTime createdAt;

  ToolRecordEntity();

  static final _$ToolRecordEntityTable $table = _$ToolRecordEntityTable();
}

// ── Sessions ──────────────────────────────────────────────────────────────────

/// A single agent session (wraps one or many [EnvoyAgent.run] calls).
@StanzaEntity(name: 'envoy_sessions', snakeCase: true)
class SessionEntity {
  /// Caller-supplied or generated session ID (hex string).
  late String id;

  late DateTime createdAt;

  SessionEntity();

  static final _$SessionEntityTable $table = _$SessionEntityTable();
}

// ── Messages ──────────────────────────────────────────────────────────────────

/// A single message within a session's conversation history.
@StanzaEntity(name: 'envoy_messages', snakeCase: true)
class MessageEntity {
  @StanzaField(readOnly: true)
  late int id;

  late String sessionId;

  /// JSON-encoded anthropic.Message (via toJson/fromJson).
  late String content;

  late int sortOrder;

  late DateTime createdAt;

  MessageEntity();

  static final _$MessageEntityTable $table = _$MessageEntityTable();
}
