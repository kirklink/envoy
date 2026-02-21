import 'dart:convert';
import 'dart:math' as math;

import 'config.dart';
import 'llm_callback.dart';
import 'models/entity.dart';
import 'models/memory.dart';
import 'models/relationship.dart';
import 'store/episode_entity.dart';
import 'store/souvenir_store.dart';

const _systemPrompt = '''
You are extracting durable knowledge from an agent's recent experience.
Output a JSON object with this exact structure (no other text):

{
  "facts": [
    {
      "content": "A standalone, self-contained statement of fact",
      "entities": [{"name": "EntityName", "type": "person|project|concept|preference|fact"}],
      "importance": 0.7
    }
  ],
  "relationships": [
    {"from": "EntityName", "to": "OtherEntity", "relation": "uses", "confidence": 0.9}
  ]
}

Rules:
- Be conservative. Only extract what matters for future sessions.
- Each fact should be a standalone statement — understandable without context.
- Normalize entity names: consistent casing, no abbreviations.
- Importance reflects long-term value: preferences 0.9, project facts 0.7, transient details 0.3.
- If nothing is worth extracting, return: {"facts": [], "relationships": []}
''';

/// Result counters from a consolidation run.
class ConsolidationResult {
  final int sessionsProcessed;
  final int sessionsSkipped;
  final int memoriesCreated;
  final int memoriesMerged;
  final int entitiesUpserted;
  final int relationshipsUpserted;
  final int memoriesDecayed;

  const ConsolidationResult({
    this.sessionsProcessed = 0,
    this.sessionsSkipped = 0,
    this.memoriesCreated = 0,
    this.memoriesMerged = 0,
    this.entitiesUpserted = 0,
    this.relationshipsUpserted = 0,
    this.memoriesDecayed = 0,
  });
}

/// Extracts durable knowledge from episodic memory via LLM.
///
/// The pipeline:
/// 1. Queries unconsolidated episodes, groups by session
/// 2. Calls LLM to extract facts, entities, relationships
/// 3. Merges or inserts memories, upserts entities/relationships
/// 4. Marks source episodes as consolidated
/// 5. Applies importance decay to stale memories
class ConsolidationPipeline {
  final SouvenirStore _store;
  final LlmCallback _llm;
  final SouvenirConfig _config;

  ConsolidationPipeline(this._store, this._llm, this._config);

  /// Runs the full consolidation pipeline.
  Future<ConsolidationResult> run() async {
    // 1. Fetch unconsolidated episodes.
    final episodes = await _store.unconsolidatedEpisodes(
      minAge: _config.consolidationMinAge,
    );

    if (episodes.isEmpty) {
      final decayed = await _applyDecay();
      return ConsolidationResult(memoriesDecayed: decayed);
    }

    // 2. Group by session.
    final groups = <String, List<EpisodeEntity>>{};
    for (final ep in episodes) {
      groups.putIfAbsent(ep.sessionId, () => []).add(ep);
    }

    var sessionsProcessed = 0;
    var sessionsSkipped = 0;
    var memoriesCreated = 0;
    var memoriesMerged = 0;
    var entitiesUpserted = 0;
    var relationshipsUpserted = 0;

    // 3. Process each session group.
    for (final entry in groups.entries) {
      try {
        final counts = await _processSessionGroup(entry.key, entry.value);
        sessionsProcessed++;
        memoriesCreated += counts.created;
        memoriesMerged += counts.merged;
        entitiesUpserted += counts.entities;
        relationshipsUpserted += counts.relationships;
      } catch (_) {
        // LLM failure or JSON parse error — skip this session.
        // Episodes remain unconsolidated for retry.
        sessionsSkipped++;
      }
    }

    // 4. Importance decay.
    final decayed = await _applyDecay();

    return ConsolidationResult(
      sessionsProcessed: sessionsProcessed,
      sessionsSkipped: sessionsSkipped,
      memoriesCreated: memoriesCreated,
      memoriesMerged: memoriesMerged,
      entitiesUpserted: entitiesUpserted,
      relationshipsUpserted: relationshipsUpserted,
      memoriesDecayed: decayed,
    );
  }

  Future<({int created, int merged, int entities, int relationships})>
      _processSessionGroup(
    String sessionId,
    List<EpisodeEntity> episodes,
  ) async {
    // Build the user prompt from episode content.
    final buffer = StringBuffer();
    for (final ep in episodes) {
      buffer.writeln('[${ep.type}] ${ep.content}');
    }

    // Call LLM.
    final response = await _llm(_systemPrompt, buffer.toString());

    // Parse JSON (handle markdown code fences).
    final extraction = _parseJson(response);

    var created = 0;
    var merged = 0;
    var entitiesCount = 0;
    var relationshipsCount = 0;

    // Process facts → memories.
    final facts = extraction['facts'] as List<dynamic>? ?? [];
    for (final fact in facts) {
      final factMap = fact as Map<String, dynamic>;
      final content = factMap['content'] as String;
      final importance =
          (factMap['importance'] as num?)?.toDouble() ?? _config.defaultImportance;
      final entityList = factMap['entities'] as List<dynamic>? ?? [];

      // Extract entity names for this fact.
      final entityNames = <String>[];
      for (final e in entityList) {
        if (e is Map<String, dynamic>) {
          entityNames.add(e['name'] as String);
        } else if (e is String) {
          entityNames.add(e);
        }
      }

      // Upsert entities referenced by this fact.
      final entityIds = <String>[];
      for (final e in entityList) {
        if (e is Map<String, dynamic>) {
          final name = e['name'] as String;
          final typeName = e['type'] as String? ?? 'concept';
          final entityType = EntityType.values.firstWhere(
            (t) => t.name == typeName,
            orElse: () => EntityType.concept,
          );

          // Check if entity already exists.
          var existing = await _store.findEntityByName(name);
          if (existing != null) {
            entityIds.add(existing.id);
          } else {
            final entity = Entity(name: name, type: entityType);
            await _store.upsertEntity(entity);
            entityIds.add(entity.id);
            entitiesCount++;
          }
        }
      }

      // Check for existing similar memory.
      final episodeIds = episodes.map((ep) => ep.id).toList();
      final existing = await _store.searchMemories(content, limit: 1);

      if (existing.isNotEmpty && existing.first.score > _config.mergeThreshold) {
        // Merge into existing memory.
        final match = existing.first.entity;
        final oldEntityIds = match.entityIds != null
            ? (jsonDecode(match.entityIds!) as List).cast<String>()
            : <String>[];
        final oldSourceIds = match.sourceIds != null
            ? (jsonDecode(match.sourceIds!) as List).cast<String>()
            : <String>[];

        await _store.updateMemory(
          match.id,
          content: content,
          importance: math.max(match.importance, importance),
          entityIds: {...oldEntityIds, ...entityIds}.toList(),
          sourceIds: {...oldSourceIds, ...episodeIds}.toList(),
        );
        merged++;
      } else {
        // Insert new memory.
        final memory = Memory(
          content: content,
          entityIds: entityIds,
          importance: importance,
          sourceEpisodeIds: episodeIds,
        );
        await _store.insertMemory(memory);
        created++;
      }
    }

    // Process relationships.
    final rels = extraction['relationships'] as List<dynamic>? ?? [];
    for (final rel in rels) {
      final relMap = rel as Map<String, dynamic>;
      final fromName = relMap['from'] as String;
      final toName = relMap['to'] as String;
      final relation = relMap['relation'] as String;
      final confidence =
          (relMap['confidence'] as num?)?.toDouble() ?? _config.defaultConfidence;

      // Resolve entity IDs (create if needed).
      var fromEntity = await _store.findEntityByName(fromName);
      if (fromEntity == null) {
        final entity = Entity(name: fromName, type: EntityType.concept);
        await _store.upsertEntity(entity);
        fromEntity = await _store.findEntityByName(fromName);
        entitiesCount++;
      }

      var toEntity = await _store.findEntityByName(toName);
      if (toEntity == null) {
        final entity = Entity(name: toName, type: EntityType.concept);
        await _store.upsertEntity(entity);
        toEntity = await _store.findEntityByName(toName);
        entitiesCount++;
      }

      await _store.upsertRelationship(Relationship(
        fromEntityId: fromEntity!.id,
        toEntityId: toEntity!.id,
        relation: relation,
        confidence: confidence,
      ));
      relationshipsCount++;
    }

    // Mark episodes as consolidated.
    await _store.markConsolidated(episodes.map((ep) => ep.id).toList());

    return (
      created: created,
      merged: merged,
      entities: entitiesCount,
      relationships: relationshipsCount,
    );
  }

  Future<int> _applyDecay() async {
    return _store.applyImportanceDecay(
      inactivePeriod: _config.decayInactivePeriod,
      decayRate: _config.importanceDecayRate,
    );
  }

  /// Parses JSON from LLM response, handling markdown code fences.
  static Map<String, dynamic> _parseJson(String response) {
    var text = response.trim();

    // Strip markdown code fences: ```json ... ``` or ``` ... ```
    if (text.startsWith('```')) {
      final firstNewline = text.indexOf('\n');
      if (firstNewline != -1) {
        text = text.substring(firstNewline + 1);
      }
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
      text = text.trim();
    }

    return jsonDecode(text) as Map<String, dynamic>;
  }
}
