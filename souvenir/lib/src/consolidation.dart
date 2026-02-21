import 'dart:convert';
import 'dart:math' as math;

import 'config.dart';
import 'embedding_provider.dart';
import 'llm_callback.dart';
import 'models/entity.dart';
import 'models/memory.dart';
import 'models/relationship.dart';
import 'personality.dart';
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
  final int memoriesEmbedded;
  final bool personalityUpdated;

  const ConsolidationResult({
    this.sessionsProcessed = 0,
    this.sessionsSkipped = 0,
    this.memoriesCreated = 0,
    this.memoriesMerged = 0,
    this.entitiesUpserted = 0,
    this.relationshipsUpserted = 0,
    this.memoriesDecayed = 0,
    this.memoriesEmbedded = 0,
    this.personalityUpdated = false,
  });
}

const _personalitySystemPrompt = '''
Update an agent's personality based on recent experience.
Write in third-person observational prose — a character study, not a config file.
Be conservative: only reflect genuine, stable shifts in behavior or perspective.
Preserve the overall structure and tone of the existing personality.
Output only the updated personality text, no explanation or preamble.
''';

/// Extracts durable knowledge from episodic memory via LLM.
///
/// The pipeline:
/// 1. Queries unconsolidated episodes, groups by session
/// 2. Calls LLM to extract facts, entities, relationships
/// 3. Merges or inserts memories, upserts entities/relationships
/// 4. Marks source episodes as consolidated
/// 5. Applies importance decay to stale memories
/// 6. Generates embeddings for new/merged memories (when provider available)
/// 7. Updates personality (when PersonalityManager is available)
class ConsolidationPipeline {
  final SouvenirStore _store;
  final LlmCallback _llm;
  final SouvenirConfig _config;
  final EmbeddingProvider? _embeddings;
  final PersonalityManager? _personality;

  ConsolidationPipeline(
    this._store,
    this._llm,
    this._config, [
    this._embeddings,
    this._personality,
  ]);

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
    final memoryIdsToEmbed = <_MemoryToEmbed>[];

    // 3. Process each session group.
    for (final entry in groups.entries) {
      try {
        final counts = await _processSessionGroup(entry.key, entry.value);
        sessionsProcessed++;
        memoriesCreated += counts.created;
        memoriesMerged += counts.merged;
        entitiesUpserted += counts.entities;
        relationshipsUpserted += counts.relationships;
        memoryIdsToEmbed.addAll(counts.toEmbed);
      } catch (_) {
        // LLM failure or JSON parse error — skip this session.
        // Episodes remain unconsolidated for retry.
        sessionsSkipped++;
      }
    }

    // 4. Importance decay.
    final decayed = await _applyDecay();

    // 5. Generate embeddings for new/merged memories.
    var embedded = 0;
    if (_embeddings != null && memoryIdsToEmbed.isNotEmpty) {
      for (final mem in memoryIdsToEmbed) {
        try {
          final vector = await _embeddings!.embed(mem.content);
          await _store.updateMemoryEmbedding(mem.id, vector);
          embedded++;
        } catch (_) {
          // Embedding failure is non-fatal — memory exists without embedding.
        }
      }
    }

    // 6. Update personality (when configured).
    var personalityUpdated = false;
    if (_personality != null && _personality!.personality != null) {
      try {
        personalityUpdated = await _updatePersonality();
      } catch (_) {
        // Personality update failure is non-fatal.
      }
    }

    return ConsolidationResult(
      sessionsProcessed: sessionsProcessed,
      sessionsSkipped: sessionsSkipped,
      memoriesCreated: memoriesCreated,
      memoriesMerged: memoriesMerged,
      entitiesUpserted: entitiesUpserted,
      relationshipsUpserted: relationshipsUpserted,
      memoriesDecayed: decayed,
      memoriesEmbedded: embedded,
      personalityUpdated: personalityUpdated,
    );
  }

  Future<({int created, int merged, int entities, int relationships, List<_MemoryToEmbed> toEmbed})>
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
    final toEmbed = <_MemoryToEmbed>[];

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
        toEmbed.add(_MemoryToEmbed(match.id, content));
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
        toEmbed.add(_MemoryToEmbed(memory.id, content));
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
      toEmbed: toEmbed,
    );
  }

  /// Gathers recent episodes and asks the LLM to update personality.
  Future<bool> _updatePersonality() async {
    final lastUpdated = _personality!.lastUpdated;
    final recentEntities = await _store.recentEpisodes(limit: 100);

    // Filter to episodes after last personality update.
    final newEpisodes = lastUpdated != null
        ? recentEntities.where((e) => e.timestamp.isAfter(lastUpdated))
        : recentEntities;

    if (newEpisodes.isEmpty) return false;

    // Build episode summary for the LLM.
    final buffer = StringBuffer();
    buffer.writeln('Current personality:');
    buffer.writeln(_personality!.personality);
    buffer.writeln();
    buffer.writeln('Recent episodes:');
    for (final ep in newEpisodes) {
      buffer.writeln('[${ep.type}] ${ep.content}');
    }

    final newText = await _llm(_personalitySystemPrompt, buffer.toString());
    return _personality!.updatePersonality(newText.trim());
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

/// Tracks a memory that needs embedding after session processing.
class _MemoryToEmbed {
  final String id;
  final String content;
  _MemoryToEmbed(this.id, this.content);
}
