import 'dart:math' as math;

import 'embedding_provider.dart';
import 'memory_store.dart';
import 'stored_memory.dart';
import 'tokenizer.dart';

/// Configuration for the unified recall pipeline.
///
/// Controls signal weights, component weights, relevance threshold,
/// and temporal decay for score fusion.
class RecallConfig {
  /// FTS5 BM25 weight in the final score.
  final double ftsWeight;

  /// Vector cosine similarity weight.
  final double vectorWeight;

  /// Entity graph weight.
  final double entityWeight;

  /// Per-component weight multipliers. Applied after signal fusion.
  /// Components not listed default to 1.0.
  final Map<String, double> componentWeights;

  /// Minimum relevance score to include in results.
  /// Memories below this threshold are dropped (silence > noise).
  final double relevanceThreshold;

  /// Maximum memories to return before budget trimming.
  final int topK;

  /// Temporal decay lambda. Higher = faster decay with age.
  /// Score multiplied by `exp(-temporalDecayLambda * ageDays)`.
  final double temporalDecayLambda;

  const RecallConfig({
    this.ftsWeight = 1.0,
    this.vectorWeight = 1.5,
    this.entityWeight = 0.8,
    this.componentWeights = const {},
    this.relevanceThreshold = 0.05,
    this.topK = 20,
    this.temporalDecayLambda = 0.005,
  });
}

/// A single recalled memory with score breakdown.
class ScoredRecall {
  /// Memory ID.
  final String id;

  /// The recalled content.
  final String content;

  /// Which component created this memory.
  final String component;

  /// Component-specific category.
  final String category;

  /// Final fused score after all weighting.
  final double score;

  /// Token count (set during budget trimming).
  final int tokens;

  /// Raw FTS signal strength (before weighting).
  final double ftsSignal;

  /// Raw vector signal strength (before weighting).
  final double vectorSignal;

  /// Raw entity graph signal strength (before weighting).
  final double entitySignal;

  const ScoredRecall({
    required this.id,
    required this.content,
    required this.component,
    required this.category,
    required this.score,
    required this.tokens,
    required this.ftsSignal,
    required this.vectorSignal,
    required this.entitySignal,
  });
}

/// Result of unified recall.
class RecallResult {
  /// Ranked memories with scores.
  final List<ScoredRecall> items;

  const RecallResult({required this.items});

  /// Total tokens consumed.
  int get totalTokens => items.fold(0, (sum, i) => sum + i.tokens);
}

/// Unified recall pipeline.
///
/// Queries the shared [MemoryStore] with three signals (FTS5, vector,
/// entity graph), fuses them using weighted linear combination, applies
/// component weights and temporal decay, filters by relevance threshold,
/// and trims to budget.
class UnifiedRecall {
  final MemoryStore _store;
  final RecallConfig _config;
  final EmbeddingProvider? _embeddings;
  final Tokenizer _tokenizer;

  UnifiedRecall({
    required MemoryStore store,
    required Tokenizer tokenizer,
    RecallConfig config = const RecallConfig(),
    EmbeddingProvider? embeddings,
  })  : _store = store,
        _config = config,
        _embeddings = embeddings,
        _tokenizer = tokenizer;

  /// The current configuration (for observability).
  RecallConfig get config => _config;

  /// Recall memories relevant to [query] within [budgetTokens].
  Future<RecallResult> recall(String query, {int budgetTokens = 4000}) async {
    // 1. Gather candidates from all signals.
    final candidates = <String, _Candidate>{};

    // Signal 1: FTS5 BM25 across all memories.
    final ftsResults = await _store.searchFts(query, limit: 50);
    double maxBm25 = 0;
    for (final m in ftsResults) {
      if (m.score > maxBm25) maxBm25 = m.score;
    }
    for (final m in ftsResults) {
      final normalized = maxBm25 > 0 ? m.score / maxBm25 : 0.0;
      _getOrCreate(candidates, m.memory).ftsScore = normalized;
    }

    // Signal 2: Vector similarity (if embeddings available).
    if (_embeddings != null) {
      final queryVec = await _embeddings!.embed(query);
      final embedded = await _store.loadActiveWithEmbeddings();
      for (final mem in embedded) {
        final sim = _cosineSimilarity(queryVec, mem.embedding!);
        if (sim > 0) {
          _getOrCreate(candidates, mem).vectorScore = sim;
        }
      }
    }

    // Signal 3: Entity graph expansion.
    await _entityGraphExpansion(query, candidates);

    if (candidates.isEmpty) return const RecallResult(items: []);

    // 2. Fuse signals into final score.
    for (final c in candidates.values) {
      final rawScore = (_config.ftsWeight * c.ftsScore) +
          (_config.vectorWeight * c.vectorScore) +
          (_config.entityWeight * c.entityScore);

      // Component weight.
      final componentWeight =
          _config.componentWeights[c.memory.component] ?? 1.0;

      // Importance multiplier.
      final importance = c.memory.importance;

      // Temporal decay.
      final ageDays =
          DateTime.now().difference(c.memory.updatedAt).inHours / 24.0;
      final decay =
          math.exp(-_config.temporalDecayLambda * math.max(0, ageDays));

      // Access frequency boost (logarithmic).
      final accessBoost = 1 + math.log(1 + c.memory.accessCount) * 0.1;

      c.finalScore =
          rawScore * componentWeight * importance * decay * accessBoost;
    }

    // 3. Filter by relevance threshold.
    candidates.removeWhere((_, c) => c.finalScore < _config.relevanceThreshold);

    // 4. Sort descending, deduplicate by content.
    final sorted = candidates.values.toList()
      ..sort((a, b) => b.finalScore.compareTo(a.finalScore));

    final seen = <String>{};
    final deduped = <_Candidate>[];
    for (final c in sorted) {
      if (seen.add(c.memory.content)) {
        deduped.add(c);
      }
    }

    // 5. Take topK.
    final limited = deduped.take(_config.topK).toList();

    // 6. Budget-aware cutoff.
    final selected = <ScoredRecall>[];
    var totalTokens = 0;
    for (final c in limited) {
      final tokens = _tokenizer.count(c.memory.content);
      if (totalTokens + tokens > budgetTokens && selected.isNotEmpty) break;

      selected.add(ScoredRecall(
        id: c.memory.id,
        content: c.memory.content,
        component: c.memory.component,
        category: c.memory.category,
        score: c.finalScore,
        tokens: tokens,
        ftsSignal: c.ftsScore,
        vectorSignal: c.vectorScore,
        entitySignal: c.entityScore,
      ));
      totalTokens += tokens;
    }

    // 7. Update access stats.
    if (selected.isNotEmpty) {
      await _store.updateAccessStats(selected.map((s) => s.id).toList());
    }

    return RecallResult(items: selected);
  }

  // ── Entity graph expansion ──────────────────────────────────────────

  Future<void> _entityGraphExpansion(
    String query,
    Map<String, _Candidate> candidates,
  ) async {
    final matchedEntities = await _store.findEntitiesByName(query);
    if (matchedEntities.isEmpty) return;

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

    final memories =
        await _store.findMemoriesByEntityIds(allEntityIds.toList());
    for (final mem in memories) {
      var bestConfidence = 0.0;
      for (final eid in mem.entityIds) {
        final conf = confidenceByEntityId[eid] ?? 0.0;
        if (conf > bestConfidence) bestConfidence = conf;
      }
      _getOrCreate(candidates, mem).entityScore = bestConfidence;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  _Candidate _getOrCreate(
    Map<String, _Candidate> candidates,
    StoredMemory memory,
  ) {
    return candidates.putIfAbsent(
      memory.id,
      () => _Candidate(memory: memory),
    );
  }

  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    final denom = na * nb;
    if (denom <= 0) return 0;
    return dot / math.sqrt(denom);
  }
}

class _Candidate {
  final StoredMemory memory;
  double ftsScore = 0;
  double vectorScore = 0;
  double entityScore = 0;
  double finalScore = 0;

  _Candidate({required this.memory});
}
