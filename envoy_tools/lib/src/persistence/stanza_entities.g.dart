// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'stanza_entities.dart';

// **************************************************************************
// StanzaEntityGenerator
// **************************************************************************

class ToolRecordEntityEntityException implements Exception {
  final String cause;
  ToolRecordEntityEntityException(this.cause);
  @override
  String toString() => cause;
}

class _$ToolRecordEntityTable extends Table<ToolRecordEntity> {
  @override
  final String $name = 'envoy_tools';
  @override
  final Type $type = ToolRecordEntity;

  Field get id => Field('envoy_tools', 'id');
  Field get name => Field('envoy_tools', 'name');
  Field get description => Field('envoy_tools', 'description');
  Field get permission => Field('envoy_tools', 'permission');
  Field get scriptPath => Field('envoy_tools', 'script_path');
  Field get inputSchema => Field('envoy_tools', 'input_schema');
  Field get createdAt => Field('envoy_tools', 'created_at');

  @override
  ToolRecordEntity fromDb(Map<String, dynamic> map) {
    return ToolRecordEntity()
      ..id = map['id'] as int
      ..name = map['name'] as String
      ..description = map['description'] as String
      ..permission = map['permission'] as String
      ..scriptPath = map['script_path'] as String
      ..inputSchema = map['input_schema'] as String
      ..createdAt = map['created_at'] as DateTime;
  }

  @override
  Map<String, dynamic> toDb(ToolRecordEntity instance) {
    return <String, dynamic>{
      'name': instance.name,
      'description': instance.description,
      'permission': instance.permission,
      'script_path': instance.scriptPath,
      'input_schema': instance.inputSchema,
      'created_at': instance.createdAt,
    };
  }
}

class SessionEntityEntityException implements Exception {
  final String cause;
  SessionEntityEntityException(this.cause);
  @override
  String toString() => cause;
}

class _$SessionEntityTable extends Table<SessionEntity> {
  @override
  final String $name = 'envoy_sessions';
  @override
  final Type $type = SessionEntity;

  Field get id => Field('envoy_sessions', 'id');
  Field get createdAt => Field('envoy_sessions', 'created_at');

  @override
  SessionEntity fromDb(Map<String, dynamic> map) {
    return SessionEntity()
      ..id = map['id'] as String
      ..createdAt = map['created_at'] as DateTime;
  }

  @override
  Map<String, dynamic> toDb(SessionEntity instance) {
    return <String, dynamic>{
      'id': instance.id,
      'created_at': instance.createdAt,
    };
  }
}

class MessageEntityEntityException implements Exception {
  final String cause;
  MessageEntityEntityException(this.cause);
  @override
  String toString() => cause;
}

class _$MessageEntityTable extends Table<MessageEntity> {
  @override
  final String $name = 'envoy_messages';
  @override
  final Type $type = MessageEntity;

  Field get id => Field('envoy_messages', 'id');
  Field get sessionId => Field('envoy_messages', 'session_id');
  Field get content => Field('envoy_messages', 'content');
  Field get sortOrder => Field('envoy_messages', 'sort_order');
  Field get createdAt => Field('envoy_messages', 'created_at');

  @override
  MessageEntity fromDb(Map<String, dynamic> map) {
    return MessageEntity()
      ..id = map['id'] as int
      ..sessionId = map['session_id'] as String
      ..content = map['content'] as String
      ..sortOrder = map['sort_order'] as int
      ..createdAt = map['created_at'] as DateTime;
  }

  @override
  Map<String, dynamic> toDb(MessageEntity instance) {
    return <String, dynamic>{
      'session_id': instance.sessionId,
      'content': instance.content,
      'sort_order': instance.sortOrder,
      'created_at': instance.createdAt,
    };
  }
}
