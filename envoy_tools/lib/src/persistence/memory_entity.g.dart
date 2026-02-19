// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'memory_entity.dart';

// **************************************************************************
// StanzaEntityGenerator
// **************************************************************************

class MemoryEntityEntityException implements Exception {
  final String cause;
  MemoryEntityEntityException(this.cause);
  @override
  String toString() => cause;
}

class _$MemoryEntityTable extends Table<MemoryEntity> {
  @override
  final String $name = 'envoy_memory';
  @override
  final Type $type = MemoryEntity;

  Field get id => Field('envoy_memory', 'id');
  Field get type => Field('envoy_memory', 'type');
  Field get content => Field('envoy_memory', 'content');
  Field get createdAt => Field('envoy_memory', 'created_at');

  @override
  MemoryEntity fromDb(Map<String, dynamic> map) {
    return MemoryEntity()
      ..id = map['id'] as int
      ..type = map['type'] as String
      ..content = map['content'] as String
      ..createdAt = map['created_at'] as DateTime;
  }

  @override
  Map<String, dynamic> toDb(MemoryEntity instance) {
    return <String, dynamic>{
      'type': instance.type,
      'content': instance.content,
      'created_at': instance.createdAt,
    };
  }

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'envoy_memory',
        columns: [
          SchemaColumn(
            name: 'id',
            type: ColumnType('integer'),
            nullable: false,
            isPrimaryKey: false,
            isSerial: false,
            isUnique: false,
          ),
          SchemaColumn(
            name: 'type',
            type: ColumnType('text'),
            nullable: false,
            isPrimaryKey: false,
            isSerial: false,
            isUnique: false,
          ),
          SchemaColumn(
            name: 'content',
            type: ColumnType('text'),
            nullable: false,
            isPrimaryKey: false,
            isSerial: false,
            isUnique: false,
          ),
          SchemaColumn(
            name: 'created_at',
            type: ColumnType('timestamptz'),
            nullable: false,
            isPrimaryKey: false,
            isSerial: false,
            isUnique: false,
          ),
        ],
        constraints: [],
      );
}
