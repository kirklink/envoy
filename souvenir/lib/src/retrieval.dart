import 'dart:convert';
import 'dart:math' as math;

import 'config.dart';
import 'embedding_provider.dart';
import 'models/recall.dart';
import 'store/memory_entity.dart';
import 'store/souvenir_store.dart';

/// Multi-signal retrieval pipeline with RRF fusion and score adjustments.
///
/// Separated from [Souvenir] for testability and single responsibility,
/// following the [ConsolidationPipeline] pattern.
///
/// Pipeline stages:
/// 1. Gather ranked lists from each signal (BM25 episodic, BM25 semantic,
///    vector similarity, entity graph expansion).
/// 2. Reciprocal Rank Fusion — fuse by ID.
/// 3. Score adjustments — temporal decay, importance boost, access frequency.
/// 4. Sort, deduplicate by exact content match.
/// 5. Filter by minImportance, take topK, apply token budget.
/// 6. Update access stats.
class RetrievalPipeline {
  final SouvenirStore _store;
  final SouvenirConfig _config;
  final EmbeddingProvider? _embeddings;

  RetrievalPipeline(this._store, this._config, [this._embeddings]);

  /// Runs the full retrieval pipeline for [query].
  Future<List<Recall>> run(String query, RecallOptions options) async {
    final rankedLists = <List<_RankedCandidate>>[];

    // Signal 1: BM25 over episodes.
    if (options.includeEpisodic) {
      final episodic = await _searchEpisodes(query, options);
      if (episodic.isNotEmpty) rankedLists.add(episodic);
    }

    // Signal 2: BM25 over memories.
    if (options.includeSemantic) {
      final semantic = await _searchMemories(query, options);
      if (semantic.isNotEmpty) rankedLists.add(semantic);
    }

    // Signal 3: Vector similarity over memory embeddings.
    if (_embeddings != null) {
      final vector = await _searchByVector(query);
      if (vector.isNotEmpty) rankedLists.add(vector);
    }

    // Signal 4: Entity graph expansion.
    final entityResults = await _expandEntityGraph(query);
    if (entityResults.isNotEmpty) rankedLists.add(entityResults);

    if (rankedLists.isEmpty) return [];

    // Stage 2: Reciprocal Rank Fusion.
    final fused = _reciprocalRankFusion(rankedLists);

    // Stage 3: Score adjustments (in spec order).
    _applyScoreAdjustments(fused);

    // Stage 4: Sort descending, deduplicate by exact content.
    final sorted = fused.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final seen = <String>{};
    final deduped = <_FusedCandidate>[];
    for (final candidate in sorted) {
      if (seen.add(candidate.content)) {
        deduped.add(candidate);
      }
    }

    // Stage 5: Filter, topK, token budget.
    var results = deduped.toList();
    if (options.minImportance != null) {
      results =
          results.where((c) => c.importance >= options.minImportance!).toList();
    }

    var limited = results.take(options.topK).toList();

    if (options.tokenBudget != null) {
      limited = _applyTokenBudget(limited, options.tokenBudget!);
    }

    // Convert to Recall objects.
    final recalls = limited
        .map((c) => Recall(
              id: c.id,
              content: c.content,
              score: c.score,
              source: c.source,
              timestamp: c.timestamp,
              importance: c.importance,
            ))
        .toList();

    // Stage 6: Update access stats for returned results.
    final episodicIds = recalls
        .where((r) => r.source == RecallSource.episodic)
        .map((r) => r.id)
        .toList();
    final semanticIds = recalls
        .where((r) =>
            r.source == RecallSource.semantic ||
            r.source == RecallSource.entity ||
            r.source == RecallSource.vector)
        .map((r) => r.id)
        .toList();

    await _store.updateAccessStats(episodicIds);
    await _store.updateMemoryAccessStats(semanticIds);

    return recalls;
  }

  // ── Signal methods ────────────────────────────────────────────────────────

  Future<List<_RankedCandidate>> _searchEpisodes(
    String query,
    RecallOptions options,
  ) async {
    final results = await _store.searchEpisodes(
      query,
      limit: options.topK * 2, // Extra for better RRF fusion.
      sessionId: options.sessionId,
    );

    return results.indexed.map((entry) {
      final (i, r) = entry;
      return _RankedCandidate(
        id: r.entity.id,
        content: r.entity.content,
        source: RecallSource.episodic,
        timestamp: r.entity.timestamp,
        importance: r.entity.importance,
        accessCount: r.entity.accessCount,
        rank: i + 1, // 1-based.
      );
    }).toList();
  }

  Future<List<_RankedCandidate>> _searchMemories(
    String query,
    RecallOptions options,
  ) async {
    final results = await _store.searchMemories(
      query,
      limit: options.topK * 2,
    );

    return results.indexed.map((entry) {
      final (i, r) = entry;
      return _RankedCandidate(
        id: r.entity.id,
        content: r.entity.content,
        source: RecallSource.semantic,
        timestamp: r.entity.updatedAt,
        importance: r.entity.importance,
        accessCount: r.entity.accessCount,
        rank: i + 1,
      );
    }).toList();
  }

  /// Vector similarity search over memory embeddings.
  ///
  /// Embeds the query, loads all memories with embeddings, computes cosine
  /// similarity, and returns the top candidates ranked by similarity.
  Future<List<_RankedCandidate>> _searchByVector(String query) async {
    final queryEmbedding = await _embeddings!.embed(query);
    final memories = await _store.loadMemoriesWithEmbeddings();
    if (memories.isEmpty) return [];

    // Score each memory by cosine similarity.
    final scored = <({MemoryWithEmbedding memory, double similarity})>[];
    for (final mem in memories) {
      final sim = _cosineSimilarity(queryEmbedding, mem.embedding);
      if (sim > 0) {
        scored.add((memory: mem, similarity: sim));
      }
    }

    // Sort by similarity descending, take top candidates.
    scored.sort((a, b) => b.similarity.compareTo(a.similarity));
    final topK = scored.take(_config.embeddingTopK).toList();

    return topK.indexed.map((entry) {
      final (i, s) = entry;
      return _RankedCandidate(
        id: s.memory.id,
        content: s.memory.content,
        source: RecallSource.vector,
        timestamp: s.memory.updatedAt,
        importance: s.memory.importance,
        accessCount: s.memory.accessCount,
        rank: i + 1,
      );
    }).toList();
  }

  /// 1-hop entity graph expansion.
  ///
  /// 1. Find entity names that appear in the query.
  /// 2. For each matched entity, find its relationships.
  /// 3. Collect all connected entity IDs (including the original).
  /// 4. Find memories associated with any of those entity IDs.
  /// 5. Score by relationship confidence.
  Future<List<_RankedCandidate>> _expandEntityGraph(String query) async {
    // Step 1: Find entities mentioned in the query.
    final matchedEntities = await _store.findEntitiesByNameMatch(query);
    if (matchedEntities.isEmpty) return [];

    // Step 2+3: Expand via relationships to connected entities.
    final allEntityIds = <String>{};
    final confidenceByEntityId = <String, double>{};

    for (final entity in matchedEntities) {
      allEntityIds.add(entity.id);
      confidenceByEntityId[entity.id] = 1.0; // Direct match = full confidence.

      final rels = await _store.findRelationshipsForEntity(entity.id);
      for (final rel in rels) {
        final connectedId =
            rel.fromEntity == entity.id ? rel.toEntity : rel.fromEntity;
        allEntityIds.add(connectedId);
        // Keep highest confidence if an entity is reached via multiple paths.
        final existing = confidenceByEntityId[connectedId] ?? 0.0;
        if (rel.confidence > existing) {
          confidenceByEntityId[connectedId] = rel.confidence;
        }
      }
    }

    // Step 4: Find memories for these entity IDs.
    final memories = await _store.findMemoriesByEntityIds(
      allEntityIds.toList(),
    );
    if (memories.isEmpty) return [];

    // Step 5: Score by confidence and sort.
    final scored = <({MemoryEntity memory, double confidence})>[];
    for (final mem in memories) {
      final memEntityIds = mem.entityIds != null
          ? (jsonDecode(mem.entityIds!) as List).cast<String>()
          : <String>[];
      var bestConfidence = 0.0;
      for (final eid in memEntityIds) {
        final conf = confidenceByEntityId[eid] ?? 0.0;
        if (conf > bestConfidence) bestConfidence = conf;
      }
      scored.add((memory: mem, confidence: bestConfidence));
    }

    // Sort by confidence descending (determines rank for RRF).
    scored.sort((a, b) => b.confidence.compareTo(a.confidence));

    return scored.indexed.map((entry) {
      final (i, s) = entry;
      return _RankedCandidate(
        id: s.memory.id,
        content: s.memory.content,
        source: RecallSource.entity,
        timestamp: s.memory.updatedAt,
        importance: s.memory.importance,
        accessCount: s.memory.accessCount,
        rank: i + 1,
      );
    }).toList();
  }

  // ── Fusion + adjustments ──────────────────────────────────────────────────

  /// Fuses multiple ranked lists into a single scored map using RRF.
  ///
  /// For each item, fused score = sum(1 / (rank + k)) across all lists
  /// where the item appears. Items in multiple lists get higher scores.
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
            source: candidate.source,
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

  /// Applies score adjustments in spec order.
  void _applyScoreAdjustments(Map<String, _FusedCandidate> fused) {
    final now = DateTime.now();

    for (final candidate in fused.values) {
      // 1. Temporal decay: score * e^(-lambda * age_days).
      final ageDays = now.difference(candidate.timestamp).inHours / 24.0;
      candidate.score *=
          math.exp(-_config.temporalDecayLambda * math.max(0, ageDays));

      // 2. Importance boost: score * importance.
      candidate.score *= candidate.importance;

      // 3. Access frequency: score * (1 + log(1 + access_count)).
      //    The +1 ensures zero-access items aren't penalized (floor of 1.0x).
      candidate.score *= 1 + math.log(1 + candidate.accessCount);
    }
  }

  /// Trims the result list to fit within [budget] estimated tokens.
  List<_FusedCandidate> _applyTokenBudget(
    List<_FusedCandidate> candidates,
    int budget,
  ) {
    final result = <_FusedCandidate>[];
    var usedTokens = 0;
    for (final c in candidates) {
      final tokens = (c.content.length / _config.tokenEstimationDivisor).ceil();
      if (usedTokens + tokens > budget) break;
      result.add(c);
      usedTokens += tokens;
    }
    return result;
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Cosine similarity between two vectors. Returns 0.0 for mismatched lengths
/// or zero-magnitude vectors.
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

// ── Internal types ──────────────────────────────────────────────────────────

/// A scored candidate from one retrieval signal, before fusion.
class _RankedCandidate {
  final String id;
  final String content;
  final RecallSource source;
  final DateTime timestamp;
  final double importance;
  final int accessCount;

  /// 1-based rank within this signal's result list.
  final int rank;

  _RankedCandidate({
    required this.id,
    required this.content,
    required this.source,
    required this.timestamp,
    required this.importance,
    required this.accessCount,
    required this.rank,
  });
}

/// Mutable working object after RRF fusion.
class _FusedCandidate {
  final String id;
  final String content;
  final RecallSource source;
  final DateTime timestamp;
  final double importance;
  final int accessCount;
  double score;

  _FusedCandidate({
    required this.id,
    required this.content,
    required this.source,
    required this.timestamp,
    required this.importance,
    required this.accessCount,
    required this.score,
  });
}
