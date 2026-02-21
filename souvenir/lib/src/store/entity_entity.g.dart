// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'entity_entity.dart';

// **************************************************************************
// EntityGenerator
// **************************************************************************

class $EntityRecordTable extends TableDescriptor<EntityRecord> {
  @override
  String get tableName => 'entities';

  final id = const StringColumn('id', 'entities');
  final name = const StringColumn('name', 'entities');
  final type = const StringColumn('type', 'entities');

  @override
  List<Column> get columns => [id, name, type];

  @override
  Column get primaryKey => id;

  @override
  EntityRecord fromRow(Map<String, dynamic> row) => EntityRecord(
        id: row['id'] as String,
        name: row['name'] as String,
        type: row['type'] as String,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'entities',
        columns: [
          SchemaColumn(
              name: 'id',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false,
              isPrimaryKey: true),
          SchemaColumn(
              name: 'name',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'type',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
        ],
        constraints: [
          SchemaConstraint(
              name: 'entities_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['id']),
        ],
      );
}

class EntityRecordInsert {
  final String id;
  final String name;
  final String type;

  const EntityRecordInsert({
    required this.id,
    required this.name,
    required this.type,
  });

  Map<String, dynamic> toRow() => {
        'id': id,
        'name': name,
        'type': type,
      };
}

class EntityRecordUpdate {
  final String? name;
  final String? type;

  const EntityRecordUpdate({
    this.name,
    this.type,
  });

  Map<String, dynamic> toRow() => {
        if (name != null) 'name': name,
        if (type != null) 'type': type,
      };
}

extension EntityRecordCopyWith on EntityRecord {
  EntityRecord copyWith({
    String? id,
    String? name,
    String? type,
  }) =>
      EntityRecord(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
      );
}
