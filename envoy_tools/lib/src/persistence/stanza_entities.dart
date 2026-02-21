import 'package:stanza/stanza.dart';

part 'stanza_entities.g.dart';

// ── Tool registry ─────────────────────────────────────────────────────────────

/// Persisted record of a dynamically registered tool.
@Entity(name: 'envoy_tools')
class ToolRecordEntity {
  @PrimaryKey(autoIncrement: true)
  final int id;

  /// Unique tool name (snake_case).
  @Field(unique: true)
  final String name;

  final String description;

  /// ToolPermission.name (compute, readFile, writeFile, network, process).
  final String permission;

  /// Absolute path to the Dart script on disk.
  final String scriptPath;

  /// JSON-encoded inputSchema map.
  final String inputSchema;

  @Field(defaultValue: 'now()')
  final DateTime createdAt;

  const ToolRecordEntity({
    required this.id,
    required this.name,
    required this.description,
    required this.permission,
    required this.scriptPath,
    required this.inputSchema,
    required this.createdAt,
  });
}

// ── Sessions ──────────────────────────────────────────────────────────────────

/// A single agent session (wraps one or many [EnvoyAgent.run] calls).
@Entity(name: 'envoy_sessions')
class SessionEntity {
  /// Caller-supplied or generated session ID (hex string).
  @PrimaryKey(autoIncrement: false)
  @Field(type: 'text')
  final String id;

  @Field(defaultValue: 'now()')
  final DateTime createdAt;

  const SessionEntity({
    required this.id,
    required this.createdAt,
  });
}

// ── Messages ──────────────────────────────────────────────────────────────────

/// A single message within a session's conversation history.
@Entity(name: 'envoy_messages')
class MessageEntity {
  @PrimaryKey(autoIncrement: true)
  final int id;

  @References(SessionEntity, onDelete: 'CASCADE')
  final String sessionId;

  /// JSON-encoded anthropic.Message (via toJson/fromJson).
  final String content;

  final int sortOrder;

  @Field(defaultValue: 'now()')
  final DateTime createdAt;

  const MessageEntity({
    required this.id,
    required this.sessionId,
    required this.content,
    required this.sortOrder,
    required this.createdAt,
  });
}
