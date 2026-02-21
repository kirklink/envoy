// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'memory_entity.dart';

// **************************************************************************
// EntityGenerator
// **************************************************************************

class $MemoryEntityTable extends TableDescriptor<MemoryEntity> {
  @override
  String get tableName => 'envoy_memory';

  final id = const IntColumn('id', 'envoy_memory');
  final type = const StringColumn('type', 'envoy_memory');
  final content = const StringColumn('content', 'envoy_memory');
  final createdAt = const DateTimeColumn('created_at', 'envoy_memory');

  @override
  List<Column> get columns => [id, type, content, createdAt];

  @override
  Column get primaryKey => id;

  @override
  MemoryEntity fromRow(Map<String, dynamic> row) => MemoryEntity(
        id: row['id'] as int,
        type: row['type'] as String,
        content: row['content'] as String,
        createdAt: row['created_at'] as DateTime,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'envoy_memory',
        columns: [
          SchemaColumn(
              name: 'id',
              type: ColumnType('serial'),
              dartTypeName: 'int',
              isPrimaryKey: true,
              isSerial: true),
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
              name: 'created_at',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false,
              defaultValue: 'now()'),
        ],
        constraints: [
          SchemaConstraint(
              name: 'envoy_memory_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['id']),
        ],
      );
}

class MemoryEntityInsert {
  final String type;
  final String content;
  final DateTime? createdAt;

  const MemoryEntityInsert({
    required this.type,
    required this.content,
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        'type': type,
        'content': content,
        if (createdAt != null) 'created_at': createdAt,
      };
}

class MemoryEntityUpdate {
  final String? type;
  final String? content;
  final DateTime? createdAt;

  const MemoryEntityUpdate({
    this.type,
    this.content,
    this.createdAt,
  });

  Map<String, dynamic> toRow() => {
        if (type != null) 'type': type,
        if (content != null) 'content': content,
        if (createdAt != null) 'created_at': createdAt,
      };
}

extension MemoryEntityCopyWith on MemoryEntity {
  MemoryEntity copyWith({
    int? id,
    String? type,
    String? content,
    DateTime? createdAt,
  }) =>
      MemoryEntity(
        id: id ?? this.id,
        type: type ?? this.type,
        content: content ?? this.content,
        createdAt: createdAt ?? this.createdAt,
      );
}
