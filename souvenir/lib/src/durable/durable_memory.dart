import 'dart:convert';
import 'dart:math' as math;

import 'package:ulid/ulid.dart';

import '../budget.dart';
import '../embedding_provider.dart';
import '../labeled_recall.dart';
import '../llm_callback.dart';
import '../memory_component.dart';
import '../models/episode.dart';
import 'durable_memory_config.dart';
import 'durable_memory_store.dart';
import 'stored_memory.dart';

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
/// Implements [MemoryComponent] with:
/// - Selective LLM extraction (high bar for inclusion)
/// - Conflict resolution (duplicate/update/contradiction)
/// - Temporal validity (validAt/invalidAt/supersededBy)
/// - Multi-signal retrieval (BM25 + entity graph + optional vector)
/// - RRF fusion with score adjustments
class DurableMemory implements MemoryComponent {
  @override
  final String name;

  final DurableMemoryStore _store;
  final DurableMemoryConfig _config;
  final EmbeddingProvider? _embeddings;

  DurableMemory({
    this.name = 'durable',
    required DurableMemoryStore store,
    DurableMemoryConfig? config,
    EmbeddingProvider? embeddings,
  })  : _store = store,
        _config = config ?? const DurableMemoryConfig(),
        _embeddings = embeddings;

  @override
  Future<void> initialize() async {
    await _store.initialize();
  }

  @override
  Future<void> close() async {
    // DB connection is owned externally.
  }

  // ── Consolidation ───────────────────────────────────────────────────────

  @override
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
    ComponentBudget budget,
  ) async {
    if (episodes.isEmpty) {
      final decayed = await _applyDecay();
      return ConsolidationReport(
        componentName: name,
        itemsDecayed: decayed,
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
      // LLM failure or parse error — skip this batch, apply decay only.
      final decayed = await _applyDecay();
      return ConsolidationReport(
        componentName: name,
        itemsDecayed: decayed,
      );
    }

    var created = 0;
    var merged = 0;
    final toEmbed = <({String id, String content})>[];

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

          final existing = await _store.findEntityByName(entityName);
          if (existing != null) {
            entityIds.add(existing.id);
          } else {
            final id = Ulid().toString();
            await _store.upsertEntity(
              id: id,
              name: entityName,
              type: typeName,
            );
            entityIds.add(id);
          }
        }
      }

      final episodeIds = episodes.map((ep) => ep.id).toList();

      // Search for existing similar memory.
      final existing = await _store.searchMemories(content, limit: 1);

      if (existing.isNotEmpty &&
          existing.first.score > _config.mergeThreshold) {
        // Existing match found — apply conflict resolution.
        final match = existing.first.memory;

        switch (conflict) {
          case 'duplicate':
            // Skip if existing importance is >= new. Otherwise merge to
            // boost importance.
            if (match.importance >= importance) continue;
            // Fall through to update logic.
            await _store.updateMemory(
              match.id,
              importance: math.max(match.importance, importance),
              entityIds: {...match.entityIds, ...entityIds}.toList(),
              sourceIds: {
                ...match.sourceEpisodeIds,
                ...episodeIds,
              }.toList(),
            );
            toEmbed.add((id: match.id, content: match.content));
            merged++;

          case 'contradiction':
            // Supersede old memory, insert new.
            final newMemory = StoredMemory(
              content: content,
              importance: importance,
              entityIds: entityIds,
              sourceEpisodeIds: episodeIds,
            );
            await _store.insertMemory(newMemory);
            await _store.supersede(match.id, newMemory.id);
            toEmbed.add((id: newMemory.id, content: content));
            created++;

          case 'update':
          default:
            // Merge: update content, keep higher importance.
            final mergedEntityIds = {
              ...match.entityIds,
              ...entityIds,
            }.toList();
            final mergedSourceIds = {
              ...match.sourceEpisodeIds,
              ...episodeIds,
            }.toList();

            await _store.updateMemory(
              match.id,
              content: content,
              importance: math.max(match.importance, importance),
              entityIds: mergedEntityIds,
              sourceIds: mergedSourceIds,
            );
            toEmbed.add((id: match.id, content: content));
            merged++;
        }
      } else {
        // No match — insert new memory.
        final memory = StoredMemory(
          content: content,
          importance: importance,
          entityIds: entityIds,
          sourceEpisodeIds: episodeIds,
        );
        await _store.insertMemory(memory);
        toEmbed.add((id: memory.id, content: content));
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
      var fromEntity = await _store.findEntityByName(fromName);
      if (fromEntity == null) {
        final id = Ulid().toString();
        await _store.upsertEntity(id: id, name: fromName, type: 'concept');
        fromEntity = (id: id, name: fromName, type: 'concept');
      }

      var toEntity = await _store.findEntityByName(toName);
      if (toEntity == null) {
        final id = Ulid().toString();
        await _store.upsertEntity(id: id, name: toName, type: 'concept');
        toEntity = (id: id, name: toName, type: 'concept');
      }

      await _store.upsertRelationship(
        fromEntity: fromEntity.id,
        toEntity: toEntity.id,
        relation: relation,
        confidence: confidence,
      );
    }

    // Importance decay.
    final decayed = await _applyDecay();

    // Generate embeddings.
    if (_embeddings != null) {
      for (final mem in toEmbed) {
        try {
          final vector = await _embeddings!.embed(mem.content);
          await _store.updateMemoryEmbedding(mem.id, vector);
        } catch (_) {
          // Embedding failure is non-fatal.
        }
      }
    }

    return ConsolidationReport(
      componentName: name,
      itemsCreated: created,
      itemsMerged: merged,
      itemsDecayed: decayed,
      episodesConsumed: episodes.length,
    );
  }

  // ── Recall ──────────────────────────────────────────────────────────────

  @override
  Future<List<LabeledRecall>> recall(
    String query,
    ComponentBudget budget,
  ) async {
    final rankedLists = <List<_RankedCandidate>>[];

    // Signal 1: BM25 over durable memories.
    final bm25Results = await _store.searchMemories(
      query,
      limit: _config.recallTopK * 2,
    );
    if (bm25Results.isNotEmpty) {
      rankedLists.add(bm25Results.indexed.map((entry) {
        final (i, r) = entry;
        return _RankedCandidate(
          id: r.memory.id,
          content: r.memory.content,
          timestamp: r.memory.updatedAt,
          importance: r.memory.importance,
          accessCount: r.memory.accessCount,
          rank: i + 1,
        );
      }).toList());
    }

    // Signal 2: Entity graph expansion.
    final entityResults = await _expandEntityGraph(query);
    if (entityResults.isNotEmpty) rankedLists.add(entityResults);

    // Signal 3: Vector similarity (when embeddings available).
    if (_embeddings != null) {
      final vectorResults = await _searchByVector(query);
      if (vectorResults.isNotEmpty) rankedLists.add(vectorResults);
    }

    if (rankedLists.isEmpty) return [];

    // RRF fusion.
    final fused = _reciprocalRankFusion(rankedLists);

    // Score adjustments.
    _applyScoreAdjustments(fused);

    // Sort descending, deduplicate by content.
    final sorted = fused.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final seen = <String>{};
    final deduped = <_FusedCandidate>[];
    for (final candidate in sorted) {
      if (seen.add(candidate.content)) {
        deduped.add(candidate);
      }
    }

    // Take topK.
    final limited = deduped.take(_config.recallTopK).toList();

    // Budget-aware cutoff.
    final results = <LabeledRecall>[];
    final accessedIds = <String>[];
    for (final c in limited) {
      final tokens = budget.consume(c.content);
      results.add(LabeledRecall(
        componentName: name,
        content: c.content,
        score: c.score,
        metadata: {
          'id': c.id,
          'importance': c.importance,
          'tokens': tokens,
        },
      ));
      accessedIds.add(c.id);

      if (budget.isOverBudget) break;
    }

    // Update access stats.
    await _store.updateAccessStats(accessedIds);

    return results;
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  Future<int> _applyDecay() async {
    return _store.applyImportanceDecay(
      inactivePeriod: _config.decayInactivePeriod,
      decayRate: _config.importanceDecayRate,
    );
  }

  /// 1-hop entity graph expansion.
  Future<List<_RankedCandidate>> _expandEntityGraph(String query) async {
    final matchedEntities = await _store.findEntitiesByNameMatch(query);
    if (matchedEntities.isEmpty) return [];

    final allEntityIds = <String>{};
    final confidenceByEntityId = <String, double>{};

    for (final entity in matchedEntities) {
      allEntityIds.add(entity.id);
      confidenceByEntityId[entity.id] = 1.0;

      final rels = await _store.findRelationshipsForEntity(entity.id);
      for (final rel in rels) {
        final connectedId =
            rel.fromEntity == entity.id ? rel.toEntity : rel.fromEntity;
        allEntityIds.add(connectedId);
        final existing = confidenceByEntityId[connectedId] ?? 0.0;
        if (rel.confidence > existing) {
          confidenceByEntityId[connectedId] = rel.confidence;
        }
      }
    }

    final memories = await _store.findMemoriesByEntityIds(
      allEntityIds.toList(),
    );
    if (memories.isEmpty) return [];

    final scored = <({StoredMemory memory, double confidence})>[];
    for (final mem in memories) {
      var bestConfidence = 0.0;
      for (final eid in mem.entityIds) {
        final conf = confidenceByEntityId[eid] ?? 0.0;
        if (conf > bestConfidence) bestConfidence = conf;
      }
      scored.add((memory: mem, confidence: bestConfidence));
    }

    scored.sort((a, b) => b.confidence.compareTo(a.confidence));

    return scored.indexed.map((entry) {
      final (i, s) = entry;
      return _RankedCandidate(
        id: s.memory.id,
        content: s.memory.content,
        timestamp: s.memory.updatedAt,
        importance: s.memory.importance,
        accessCount: s.memory.accessCount,
        rank: i + 1,
      );
    }).toList();
  }

  /// Vector similarity search.
  Future<List<_RankedCandidate>> _searchByVector(String query) async {
    final queryEmbedding = await _embeddings!.embed(query);
    final memories = await _store.loadMemoriesWithEmbeddings();
    if (memories.isEmpty) return [];

    final scored =
        <({String id, String content, DateTime updatedAt, double importance, int accessCount, double similarity})>[];
    for (final mem in memories) {
      final sim = _cosineSimilarity(queryEmbedding, mem.embedding);
      if (sim > 0) {
        scored.add((
          id: mem.id,
          content: mem.content,
          updatedAt: mem.updatedAt,
          importance: mem.importance,
          accessCount: mem.accessCount,
          similarity: sim,
        ));
      }
    }

    scored.sort((a, b) => b.similarity.compareTo(a.similarity));
    final topK = scored.take(_config.embeddingTopK).toList();

    return topK.indexed.map((entry) {
      final (i, s) = entry;
      return _RankedCandidate(
        id: s.id,
        content: s.content,
        timestamp: s.updatedAt,
        importance: s.importance,
        accessCount: s.accessCount,
        rank: i + 1,
      );
    }).toList();
  }

  /// RRF fusion across ranked lists.
  Map<String, _FusedCandidate> _reciprocalRankFusion(
    List<List<_RankedCandidate>> rankedLists,
  ) {
    final fused = <String, _FusedCandidate>{};
    final k = _config.rrfK;

    for (final list in rankedLists) {
      for (final candidate in list) {
        final rrfScore = 1.0 / (candidate.rank + k);
        final existing = fused[candidate.id];

        if (existing != null) {
          existing.score += rrfScore;
        } else {
          fused[candidate.id] = _FusedCandidate(
            id: candidate.id,
            content: candidate.content,
            timestamp: candidate.timestamp,
            importance: candidate.importance,
            accessCount: candidate.accessCount,
            score: rrfScore,
          );
        }
      }
    }

    return fused;
  }

  /// Score adjustments: temporal decay, importance, access frequency.
  void _applyScoreAdjustments(Map<String, _FusedCandidate> fused) {
    final now = DateTime.now();

    for (final candidate in fused.values) {
      final ageDays = now.difference(candidate.timestamp).inHours / 24.0;
      candidate.score *=
          math.exp(-_config.temporalDecayLambda * math.max(0, ageDays));
      candidate.score *= candidate.importance;
      candidate.score *= 1 + math.log(1 + candidate.accessCount);
    }
  }

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

// ── Internal types ──────────────────────────────────────────────────────────

/// Cosine similarity between two vectors.
double _cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length) return 0.0;
  var dot = 0.0, normA = 0.0, normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  final denom = math.sqrt(normA) * math.sqrt(normB);
  return denom == 0 ? 0.0 : dot / denom;
}

class _RankedCandidate {
  final String id;
  final String content;
  final DateTime timestamp;
  final double importance;
  final int accessCount;
  final int rank;

  _RankedCandidate({
    required this.id,
    required this.content,
    required this.timestamp,
    required this.importance,
    required this.accessCount,
    required this.rank,
  });
}

class _FusedCandidate {
  final String id;
  final String content;
  final DateTime timestamp;
  final double importance;
  final int accessCount;
  double score;

  _FusedCandidate({
    required this.id,
    required this.content,
    required this.timestamp,
    required this.importance,
    required this.accessCount,
    required this.score,
  });
}
