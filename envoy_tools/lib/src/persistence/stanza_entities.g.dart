// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'stanza_entities.dart';

// **************************************************************************
// EntityGenerator
// **************************************************************************

class $ToolRecordEntityTable extends TableDescriptor<ToolRecordEntity> {
  @override
  String get tableName => 'envoy_tools';

  final id = const IntColumn('id', 'envoy_tools');
  final name = const StringColumn('name', 'envoy_tools');
  final description = const StringColumn('description', 'envoy_tools');
  final permission = const StringColumn('permission', 'envoy_tools');
  final scriptPath = const StringColumn('script_path', 'envoy_tools');
  final inputSchema = const StringColumn('input_schema', 'envoy_tools');
  final createdAt = const DateTimeColumn('created_at', 'envoy_tools');

  @override
  List<Column> get columns =>
      [id, name, description, permission, scriptPath, inputSchema, createdAt];

  @override
  Column get primaryKey => id;

  @override
  ToolRecordEntity fromRow(Map<String, dynamic> row) => ToolRecordEntity(
        id: row['id'] as int,
        name: row['name'] as String,
        description: row['description'] as String,
        permission: row['permission'] as String,
        scriptPath: row['script_path'] as String,
        inputSchema: row['input_schema'] as String,
        createdAt: row['created_at'] as DateTime,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'envoy_tools',
        columns: [
          SchemaColumn(
              name: 'id',
              type: ColumnType('serial'),
              dartTypeName: 'int',
              isPrimaryKey: true,
              isSerial: true),
          SchemaColumn(
              name: 'name',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false,
              isUnique: true),
          SchemaColumn(
              name: 'description',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'permission',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'script_path',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'input_schema',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'created_at',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false,
              defaultValue: 'now()'),
        ],
        constraints: [
          SchemaConstraint(
              name: 'envoy_tools_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['id']),
          SchemaConstraint(
              name: 'envoy_tools_name_key',
              kind: ConstraintKind.unique,
              columns: ['name']),
        ],
      );
}

class ToolRecordEntityInsert {
  final String name;
  final String description;
  final String permission;
  final String scriptPath;
  final String inputSchema;
  final DateTime? createdAt;

  const ToolRecordEntityInsert({
    required this.name,
    required this.description,
    required this.permission,
    required this.scriptPath,
    required this.inputSchema,
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        'name': name,
        'description': description,
        'permission': permission,
        'script_path': scriptPath,
        'input_schema': inputSchema,
        if (createdAt != null) 'created_at': createdAt,
      };
}

class ToolRecordEntityUpdate {
  final String? name;
  final String? description;
  final String? permission;
  final String? scriptPath;
  final String? inputSchema;
  final DateTime? createdAt;

  const ToolRecordEntityUpdate({
    this.name,
    this.description,
    this.permission,
    this.scriptPath,
    this.inputSchema,
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (permission != null) 'permission': permission,
        if (scriptPath != null) 'script_path': scriptPath,
        if (inputSchema != null) 'input_schema': inputSchema,
        if (createdAt != null) 'created_at': createdAt,
      };
}

extension ToolRecordEntityCopyWith on ToolRecordEntity {
  ToolRecordEntity copyWith({
    int? id,
    String? name,
    String? description,
    String? permission,
    String? scriptPath,
    String? inputSchema,
    DateTime? createdAt,
  }) =>
      ToolRecordEntity(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        permission: permission ?? this.permission,
        scriptPath: scriptPath ?? this.scriptPath,
        inputSchema: inputSchema ?? this.inputSchema,
        createdAt: createdAt ?? this.createdAt,
      );
}

class $SessionEntityTable extends TableDescriptor<SessionEntity> {
  @override
  String get tableName => 'envoy_sessions';

  final id = const StringColumn('id', 'envoy_sessions');
  final createdAt = const DateTimeColumn('created_at', 'envoy_sessions');

  @override
  List<Column> get columns => [id, createdAt];

  @override
  Column get primaryKey => id;

  @override
  SessionEntity fromRow(Map<String, dynamic> row) => SessionEntity(
        id: row['id'] as String,
        createdAt: row['created_at'] as DateTime,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'envoy_sessions',
        columns: [
          SchemaColumn(
              name: 'id',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false,
              isPrimaryKey: true),
          SchemaColumn(
              name: 'created_at',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false,
              defaultValue: 'now()'),
        ],
        constraints: [
          SchemaConstraint(
              name: 'envoy_sessions_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['id']),
        ],
      );
}

class SessionEntityInsert {
  final String id;
  final DateTime? createdAt;

  const SessionEntityInsert({
    required this.id,
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        'id': id,
        if (createdAt != null) 'created_at': createdAt,
      };
}

class SessionEntityUpdate {
  final DateTime? createdAt;

  const SessionEntityUpdate({
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        if (createdAt != null) 'created_at': createdAt,
      };
}

extension SessionEntityCopyWith on SessionEntity {
  SessionEntity copyWith({
    String? id,
    DateTime? createdAt,
  }) =>
      SessionEntity(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
      );
}

class $MessageEntityTable extends TableDescriptor<MessageEntity> {
  @override
  String get tableName => 'envoy_messages';

  final id = const IntColumn('id', 'envoy_messages');
  final sessionId = const StringColumn('session_id', 'envoy_messages');
  final content = const StringColumn('content', 'envoy_messages');
  final sortOrder = const IntColumn('sort_order', 'envoy_messages');
  final createdAt = const DateTimeColumn('created_at', 'envoy_messages');

  @override
  List<Column> get columns => [id, sessionId, content, sortOrder, createdAt];

  @override
  Column get primaryKey => id;

  @override
  MessageEntity fromRow(Map<String, dynamic> row) => MessageEntity(
        id: row['id'] as int,
        sessionId: row['session_id'] as String,
        content: row['content'] as String,
        sortOrder: row['sort_order'] as int,
        createdAt: row['created_at'] as DateTime,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'envoy_messages',
        columns: [
          SchemaColumn(
              name: 'id',
              type: ColumnType('serial'),
              dartTypeName: 'int',
              isPrimaryKey: true,
              isSerial: true),
          SchemaColumn(
              name: 'session_id',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'content',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'sort_order',
              type: ColumnType('integer'),
              dartTypeName: 'int',
              nullable: false),
          SchemaColumn(
              name: 'created_at',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false,
              defaultValue: 'now()'),
        ],
        constraints: [
          SchemaConstraint(
              name: 'envoy_messages_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['id']),
          SchemaConstraint(
              name: 'envoy_messages_session_id_fkey',
              kind: ConstraintKind.foreignKey,
              columns: ['session_id'],
              referencedTable: 'session_entitys',
              referencedColumn: 'id',
              onDelete: 'CASCADE'),
        ],
      );
}

class MessageEntityInsert {
  final String sessionId;
  final String content;
  final int sortOrder;
  final DateTime? createdAt;

  const MessageEntityInsert({
    required this.sessionId,
    required this.content,
    required this.sortOrder,
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        'session_id': sessionId,
        'content': content,
        'sort_order': sortOrder,
        if (createdAt != null) 'created_at': createdAt,
      };
}

class MessageEntityUpdate {
  final String? sessionId;
  final String? content;
  final int? sortOrder;
  final DateTime? createdAt;

  const MessageEntityUpdate({
    this.sessionId,
    this.content,
    this.sortOrder,
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        if (sessionId != null) 'session_id': sessionId,
        if (content != null) 'content': content,
        if (sortOrder != null) 'sort_order': sortOrder,
        if (createdAt != null) 'created_at': createdAt,
      };
}

extension MessageEntityCopyWith on MessageEntity {
  MessageEntity copyWith({
    int? id,
    String? sessionId,
    String? content,
    int? sortOrder,
    DateTime? createdAt,
  }) =>
      MessageEntity(
        id: id ?? this.id,
        sessionId: sessionId ?? this.sessionId,
        content: content ?? this.content,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
      );
}
