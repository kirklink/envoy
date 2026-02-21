// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'episode_entity.dart';

// **************************************************************************
// EntityGenerator
// **************************************************************************

class $EpisodeEntityTable extends TableDescriptor<EpisodeEntity> {
  @override
  String get tableName => 'episodes';

  final id = const StringColumn('id', 'episodes');
  final sessionId = const StringColumn('session_id', 'episodes');
  final timestamp = const DateTimeColumn('timestamp', 'episodes');
  final type = const StringColumn('type', 'episodes');
  final content = const StringColumn('content', 'episodes');
  final importance = const DoubleColumn('importance', 'episodes');
  final accessCount = const IntColumn('access_count', 'episodes');
  final lastAccessed = const DateTimeColumn('last_accessed', 'episodes');
  final consolidated = const IntColumn('consolidated', 'episodes');

  @override
  List<Column> get columns => [
        id,
        sessionId,
        timestamp,
        type,
        content,
        importance,
        accessCount,
        lastAccessed,
        consolidated
      ];

  @override
  Column get primaryKey => id;

  @override
  EpisodeEntity fromRow(Map<String, dynamic> row) => EpisodeEntity(
        id: row['id'] as String,
        sessionId: row['session_id'] as String,
        timestamp: row['timestamp'] as DateTime,
        type: row['type'] as String,
        content: row['content'] as String,
        importance: row['importance'] as double,
        accessCount: row['access_count'] as int,
        lastAccessed: row['last_accessed'] as DateTime?,
        consolidated: row['consolidated'] as int,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'episodes',
        columns: [
          SchemaColumn(
              name: 'id',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false,
              isPrimaryKey: true),
          SchemaColumn(
              name: 'session_id',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'timestamp',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false),
          SchemaColumn(
              name: 'type',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'content',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'importance',
              type: ColumnType('double precision'),
              dartTypeName: 'double',
              nullable: false,
              defaultValue: '0.5'),
          SchemaColumn(
              name: 'access_count',
              type: ColumnType('integer'),
              dartTypeName: 'int',
              nullable: false,
              defaultValue: '0'),
          SchemaColumn(
              name: 'last_accessed',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime'),
          SchemaColumn(
              name: 'consolidated',
              type: ColumnType('integer'),
              dartTypeName: 'int',
              nullable: false,
              defaultValue: '0'),
        ],
        constraints: [
          SchemaConstraint(
              name: 'episodes_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['id']),
        ],
      );
}

class EpisodeEntityInsert {
  final String id;
  final String sessionId;
  final DateTime timestamp;
  final String type;
  final String content;
  final double? importance;
  final int? accessCount;
  final DateTime? lastAccessed;
  final int? consolidated;

  const EpisodeEntityInsert({
    required this.id,
    required this.sessionId,
    required this.timestamp,
    required this.type,
    required this.content,
    this.importance,
    this.accessCount,
    this.lastAccessed,
    this.consolidated,
  });

  Map<String, dynamic> toRow() => {
        'id': id,
        'session_id': sessionId,
        'timestamp': timestamp,
        'type': type,
        'content': content,
        if (importance != null) 'importance': importance,
        if (accessCount != null) 'access_count': accessCount,
        if (lastAccessed != null) 'last_accessed': lastAccessed,
        if (consolidated != null) 'consolidated': consolidated,
      };
}

class EpisodeEntityUpdate {
  final String? sessionId;
  final DateTime? timestamp;
  final String? type;
  final String? content;
  final double? importance;
  final int? accessCount;
  final DateTime? lastAccessed;
  final int? consolidated;

  const EpisodeEntityUpdate({
    this.sessionId,
    this.timestamp,
    this.type,
    this.content,
    this.importance,
    this.accessCount,
    this.lastAccessed,
    this.consolidated,
  });

  Map<String, dynamic> toRow() => {
        if (sessionId != null) 'session_id': sessionId,
        if (timestamp != null) 'timestamp': timestamp,
        if (type != null) 'type': type,
        if (content != null) 'content': content,
        if (importance != null) 'importance': importance,
        if (accessCount != null) 'access_count': accessCount,
        if (lastAccessed != null) 'last_accessed': lastAccessed,
        if (consolidated != null) 'consolidated': consolidated,
      };
}

extension EpisodeEntityCopyWith on EpisodeEntity {
  EpisodeEntity copyWith({
    String? id,
    String? sessionId,
    DateTime? timestamp,
    String? type,
    String? content,
    double? importance,
    int? accessCount,
    DateTime? lastAccessed,
    int? consolidated,
  }) =>
      EpisodeEntity(
        id: id ?? this.id,
        sessionId: sessionId ?? this.sessionId,
        timestamp: timestamp ?? this.timestamp,
        type: type ?? this.type,
        content: content ?? this.content,
        importance: importance ?? this.importance,
        accessCount: accessCount ?? this.accessCount,
        lastAccessed: lastAccessed ?? this.lastAccessed,
        consolidated: consolidated ?? this.consolidated,
      );
}
