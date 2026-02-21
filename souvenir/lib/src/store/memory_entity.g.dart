// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'memory_entity.dart';

// **************************************************************************
// EntityGenerator
// **************************************************************************

class $MemoryEntityTable extends TableDescriptor<MemoryEntity> {
  @override
  String get tableName => 'memories';

  final id = const StringColumn('id', 'memories');
  final content = const StringColumn('content', 'memories');
  final entityIds = const StringColumn('entity_ids', 'memories');
  final importance = const DoubleColumn('importance', 'memories');
  final embedding = const StringColumn('embedding', 'memories');
  final createdAt = const DateTimeColumn('created_at', 'memories');
  final updatedAt = const DateTimeColumn('updated_at', 'memories');
  final sourceIds = const StringColumn('source_ids', 'memories');
  final accessCount = const IntColumn('access_count', 'memories');
  final lastAccessed = const DateTimeColumn('last_accessed', 'memories');

  @override
  List<Column> get columns => [
        id,
        content,
        entityIds,
        importance,
        embedding,
        createdAt,
        updatedAt,
        sourceIds,
        accessCount,
        lastAccessed
      ];

  @override
  Column get primaryKey => id;

  @override
  MemoryEntity fromRow(Map<String, dynamic> row) => MemoryEntity(
        id: row['id'] as String,
        content: row['content'] as String,
        entityIds: row['entity_ids'] as String?,
        importance: row['importance'] as double,
        embedding: row['embedding'] as String?,
        createdAt: row['created_at'] as DateTime,
        updatedAt: row['updated_at'] as DateTime,
        sourceIds: row['source_ids'] as String?,
        accessCount: row['access_count'] as int,
        lastAccessed: row['last_accessed'] as DateTime?,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'memories',
        columns: [
          SchemaColumn(
              name: 'id',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false,
              isPrimaryKey: true),
          SchemaColumn(
              name: 'content',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'entity_ids',
              type: ColumnType('text'),
              dartTypeName: 'String'),
          SchemaColumn(
              name: 'importance',
              type: ColumnType('double precision'),
              dartTypeName: 'double',
              nullable: false,
              defaultValue: '0.5'),
          SchemaColumn(
              name: 'embedding',
              type: ColumnType('text'),
              dartTypeName: 'String'),
          SchemaColumn(
              name: 'created_at',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false),
          SchemaColumn(
              name: 'updated_at',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false),
          SchemaColumn(
              name: 'source_ids',
              type: ColumnType('text'),
              dartTypeName: 'String'),
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
        ],
        constraints: [
          SchemaConstraint(
              name: 'memories_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['id']),
        ],
      );
}

class MemoryEntityInsert {
  final String id;
  final String content;
  final String? entityIds;
  final double? importance;
  final String? embedding;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? sourceIds;
  final int? accessCount;
  final DateTime? lastAccessed;

  const MemoryEntityInsert({
    required this.id,
    required this.content,
    this.entityIds,
    this.importance,
    this.embedding,
    required this.createdAt,
    required this.updatedAt,
    this.sourceIds,
    this.accessCount,
    this.lastAccessed,
  });

  Map<String, dynamic> toRow() => {
        'id': id,
        'content': content,
        if (entityIds != null) 'entity_ids': entityIds,
        if (importance != null) 'importance': importance,
        if (embedding != null) 'embedding': embedding,
        'created_at': createdAt,
        'updated_at': updatedAt,
        if (sourceIds != null) 'source_ids': sourceIds,
        if (accessCount != null) 'access_count': accessCount,
        if (lastAccessed != null) 'last_accessed': lastAccessed,
      };
}

class MemoryEntityUpdate {
  final String? content;
  final String? entityIds;
  final double? importance;
  final String? embedding;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? sourceIds;
  final int? accessCount;
  final DateTime? lastAccessed;

  const MemoryEntityUpdate({
    this.content,
    this.entityIds,
    this.importance,
    this.embedding,
    this.createdAt,
    this.updatedAt,
    this.sourceIds,
    this.accessCount,
    this.lastAccessed,
  });

  Map<String, dynamic> toRow() => {
        if (content != null) 'content': content,
        if (entityIds != null) 'entity_ids': entityIds,
        if (importance != null) 'importance': importance,
        if (embedding != null) 'embedding': embedding,
        if (createdAt != null) 'created_at': createdAt,
        if (updatedAt != null) 'updated_at': updatedAt,
        if (sourceIds != null) 'source_ids': sourceIds,
        if (accessCount != null) 'access_count': accessCount,
        if (lastAccessed != null) 'last_accessed': lastAccessed,
      };
}

extension MemoryEntityCopyWith on MemoryEntity {
  MemoryEntity copyWith({
    String? id,
    String? content,
    String? entityIds,
    double? importance,
    String? embedding,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? sourceIds,
    int? accessCount,
    DateTime? lastAccessed,
  }) =>
      MemoryEntity(
        id: id ?? this.id,
        content: content ?? this.content,
        entityIds: entityIds ?? this.entityIds,
        importance: importance ?? this.importance,
        embedding: embedding ?? this.embedding,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        sourceIds: sourceIds ?? this.sourceIds,
        accessCount: accessCount ?? this.accessCount,
        lastAccessed: lastAccessed ?? this.lastAccessed,
      );
}
