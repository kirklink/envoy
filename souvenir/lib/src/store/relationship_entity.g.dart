// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'relationship_entity.dart';

// **************************************************************************
// EntityGenerator
// **************************************************************************

class $RelationshipRecordTable extends TableDescriptor<RelationshipRecord> {
  @override
  String get tableName => 'relationships';

  final fromEntity = const StringColumn('from_entity', 'relationships');
  final toEntity = const StringColumn('to_entity', 'relationships');
  final relation = const StringColumn('relation', 'relationships');
  final confidence = const DoubleColumn('confidence', 'relationships');
  final updatedAt = const DateTimeColumn('updated_at', 'relationships');

  @override
  List<Column> get columns =>
      [fromEntity, toEntity, relation, confidence, updatedAt];

  @override
  Column get primaryKey => fromEntity;

  @override
  RelationshipRecord fromRow(Map<String, dynamic> row) => RelationshipRecord(
        fromEntity: row['from_entity'] as String,
        toEntity: row['to_entity'] as String,
        relation: row['relation'] as String,
        confidence: row['confidence'] as double,
        updatedAt: row['updated_at'] as DateTime,
      );

  @override
  SchemaTable get $schema => SchemaTable(
        name: 'relationships',
        columns: [
          SchemaColumn(
              name: 'from_entity',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false,
              isPrimaryKey: true),
          SchemaColumn(
              name: 'to_entity',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'relation',
              type: ColumnType('text'),
              dartTypeName: 'String',
              nullable: false),
          SchemaColumn(
              name: 'confidence',
              type: ColumnType('double precision'),
              dartTypeName: 'double',
              nullable: false,
              defaultValue: '1.0'),
          SchemaColumn(
              name: 'updated_at',
              type: ColumnType('timestamptz'),
              dartTypeName: 'DateTime',
              nullable: false),
        ],
        constraints: [
          SchemaConstraint(
              name: 'relationships_pkey',
              kind: ConstraintKind.primaryKey,
              columns: ['from_entity']),
        ],
      );
}

class RelationshipRecordInsert {
  final String fromEntity;
  final String toEntity;
  final String relation;
  final double? confidence;
  final DateTime updatedAt;

  const RelationshipRecordInsert({
    required this.fromEntity,
    required this.toEntity,
    required this.relation,
    this.confidence,
    required this.updatedAt,
  });

  Map<String, dynamic> toRow() => {
        'from_entity': fromEntity,
        'to_entity': toEntity,
        'relation': relation,
        if (confidence != null) 'confidence': confidence,
        'updated_at': updatedAt,
      };
}

class RelationshipRecordUpdate {
  final String? toEntity;
  final String? relation;
  final double? confidence;
  final DateTime? updatedAt;

  const RelationshipRecordUpdate({
    this.toEntity,
    this.relation,
    this.confidence,
    this.updatedAt,
  });

  Map<String, dynamic> toRow() => {
        if (toEntity != null) 'to_entity': toEntity,
        if (relation != null) 'relation': relation,
        if (confidence != null) 'confidence': confidence,
        if (updatedAt != null) 'updated_at': updatedAt,
      };
}

extension RelationshipRecordCopyWith on RelationshipRecord {
  RelationshipRecord copyWith({
    String? fromEntity,
    String? toEntity,
    String? relation,
    double? confidence,
    DateTime? updatedAt,
  }) =>
      RelationshipRecord(
        fromEntity: fromEntity ?? this.fromEntity,
        toEntity: toEntity ?? this.toEntity,
        relation: relation ?? this.relation,
        confidence: confidence ?? this.confidence,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
