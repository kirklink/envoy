import 'dart:convert';
import 'dart:math' as math;

import '../llm_callback.dart';
import '../memory_component.dart';
import '../memory_store.dart';
import '../models/episode.dart';
import '../stored_memory.dart';
import 'durable_memory_config.dart';

const _systemPrompt = '''
You are extracting durable knowledge from an agent's recent experience.
Only extract facts that would matter months from now, independent of any
specific task. Preferences, learned patterns, project structures, and
relationship facts qualify. Transient task context does not.

Output a JSON object with this exact structure (no other text):

{
  "facts": [
    {
      "content": "A standalone, self-contained statement of fact",
      "entities": [{"name": "EntityName", "type": "person|project|concept|preference|fact"}],
      "importance": 0.7,
      "conflict": null
    }
  ],
  "relationships": [
    {"from": "EntityName", "to": "OtherEntity", "relation": "uses", "confidence": 0.9}
  ]
}

Rules:
- Be very selective. Only extract what matters for months, not hours.
- Each fact should be a standalone statement — understandable without context.
- Normalize entity names: consistent casing, no abbreviations.
- Importance reflects long-term value: preferences 0.9, project facts 0.7, transient details 0.3.
- For each fact, set "conflict" to indicate its relationship to potentially existing knowledge:
  - null: appears to be new information
  - "duplicate": restates something likely already known
  - "update": refines or adds detail to existing knowledge
  - "contradiction": contradicts previously established knowledge
- If nothing is worth extracting, return: {"facts": [], "relationships": []}
''';

/// Durable memory component: long-lived facts, preferences, and knowledge.
///
/// Writes to the shared [MemoryStore] with `component: 'durable'`. Recall
/// is handled by the engine's unified recall pipeline.
///
/// Implements [MemoryComponent] with:
/// - Selective LLM extraction (high bar for inclusion)
/// - Conflict resolution (duplicate/update/contradiction)
/// - Entity graph management (entities + relationships in shared store)
/// - Importance decay for inactive memories
class DurableMemory implements MemoryComponent {
  @override
  final String name;

  final MemoryStore _store;
  final DurableMemoryConfig _config;

  DurableMemory({
    this.name = 'durable',
    required MemoryStore store,
    DurableMemoryConfig? config,
  })  : _store = store,
        _config = config ?? const DurableMemoryConfig();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> close() async {}

  // ── Consolidation ───────────────────────────────────────────────────────

  @override
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
  ) async {
    // Always apply importance decay, even for empty episodes.
    final itemsDecayed = await _store.applyImportanceDecay(
      component: name,
      inactivePeriod: _config.decayInactivePeriod,
      decayRate: _config.importanceDecayRate,
    );

    if (episodes.isEmpty) {
      return ConsolidationReport(
        componentName: name,
        itemsDecayed: itemsDecayed,
      );
    }

    // Build episode transcript.
    final buffer = StringBuffer();
    for (final ep in episodes) {
      buffer.writeln('[${ep.type.name}] ${ep.content}');
    }

    // Call LLM for extraction.
    Map<String, dynamic> extraction;
    try {
      final response = await llm(_systemPrompt, buffer.toString());
      extraction = _parseJson(response);
    } catch (_) {
      return ConsolidationReport(
        componentName: name,
        itemsDecayed: itemsDecayed,
      );
    }

    var created = 0;
    var merged = 0;
    final episodeIds = episodes.map((ep) => ep.id).toList();

    // Process facts.
    final facts = extraction['facts'] as List<dynamic>? ?? [];
    for (final fact in facts) {
      final factMap = fact as Map<String, dynamic>;
      final content = factMap['content'] as String;
      final importance = (factMap['importance'] as num?)?.toDouble() ??
          _config.defaultImportance;
      final conflict = factMap['conflict'] as String?;
      final entityList = factMap['entities'] as List<dynamic>? ?? [];

      // Upsert entities.
      final entityIds = <String>[];
      for (final e in entityList) {
        if (e is Map<String, dynamic>) {
          final entityName = e['name'] as String;
          final typeName = e['type'] as String? ?? 'concept';

          // Check for existing entity first.
          final existing = await _store.findEntitiesByName(entityName);
          if (existing.isNotEmpty &&
              existing.first.name.toLowerCase() == entityName.toLowerCase()) {
            entityIds.add(existing.first.id);
          } else {
            final entity = Entity(name: entityName, type: typeName);
            await _store.upsertEntity(entity);
            entityIds.add(entity.id);
          }
        }
      }

      // Search for existing similar memory in the durable component.
      final similar = await _store.findSimilar(content, name);

      if (similar.isNotEmpty) {
        // Existing match found — apply conflict resolution.
        final match = similar.first;

        switch (conflict) {
          case 'duplicate':
            // Skip if existing importance is >= new. Otherwise merge to
            // boost importance.
            if (match.importance >= importance) continue;
            // Fall through to update logic.
            await _store.update(
              match.id,
              importance: math.max(match.importance, importance),
              entityIds: {...match.entityIds, ...entityIds}.toList(),
              sourceEpisodeIds: {
                ...match.sourceEpisodeIds,
                ...episodeIds,
              }.toList(),
            );
            merged++;

          case 'contradiction':
            // Supersede old memory, insert new.
            final newMemory = StoredMemory(
              content: content,
              component: name,
              category: 'fact',
              importance: importance,
              entityIds: entityIds,
              sourceEpisodeIds: episodeIds,
            );
            await _store.insert(newMemory);
            await _store.supersede(match.id, newMemory.id);
            created++;

          case 'update':
          default:
            // Merge: update content, keep higher importance.
            await _store.update(
              match.id,
              content: content,
              importance: math.max(match.importance, importance),
              entityIds: {...match.entityIds, ...entityIds}.toList(),
              sourceEpisodeIds: {
                ...match.sourceEpisodeIds,
                ...episodeIds,
              }.toList(),
            );
            merged++;
        }
      } else {
        // No match — insert new memory.
        await _store.insert(StoredMemory(
          content: content,
          component: name,
          category: 'fact',
          importance: importance,
          entityIds: entityIds,
          sourceEpisodeIds: episodeIds,
        ));
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
      final confidence = (relMap['confidence'] as num?)?.toDouble() ??
          _config.defaultConfidence;

      // Resolve entity IDs (create if needed).
      String fromId;
      final fromEntities = await _store.findEntitiesByName(fromName);
      if (fromEntities.isNotEmpty &&
          fromEntities.first.name.toLowerCase() == fromName.toLowerCase()) {
        fromId = fromEntities.first.id;
      } else {
        final entity = Entity(name: fromName, type: 'concept');
        await _store.upsertEntity(entity);
        fromId = entity.id;
      }

      String toId;
      final toEntities = await _store.findEntitiesByName(toName);
      if (toEntities.isNotEmpty &&
          toEntities.first.name.toLowerCase() == toName.toLowerCase()) {
        toId = toEntities.first.id;
      } else {
        final entity = Entity(name: toName, type: 'concept');
        await _store.upsertEntity(entity);
        toId = entity.id;
      }

      await _store.upsertRelationship(Relationship(
        fromEntity: fromId,
        toEntity: toId,
        relation: relation,
        confidence: confidence,
      ));
    }

    return ConsolidationReport(
      componentName: name,
      itemsCreated: created,
      itemsMerged: merged,
      itemsDecayed: itemsDecayed,
      episodesConsumed: episodes.length,
    );
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  /// Parses JSON from LLM response, handling markdown code fences.
  static Map<String, dynamic> _parseJson(String response) {
    var text = response.trim();

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
