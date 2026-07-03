import 'dart:math' as math;

import 'embedding_provider.dart';
import 'memory_store.dart';
import 'stored_memory.dart';
import 'tokenizer.dart';
import 'vector_math.dart';

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

  /// Per-category weight multipliers, applied alongside
  /// [componentWeights]. Categories not listed default to 1.0.
  ///
  /// Category names are matched as-is across all components — if two
  /// components share a category name, the weight applies to both.
  final Map<String, double> categoryWeights;

  /// Components whose memories are excluded from recall entirely.
  ///
  /// A hard off-switch: excluded memories never become candidates, unlike
  /// a 0.0 entry in [componentWeights] which scores-then-discards.
  final Set<String> excludeComponents;

  /// Minimum relevance score to include in results.
  /// Memories below this threshold are dropped (silence > noise).
  final double relevanceThreshold;

  /// Maximum memories to return before budget trimming.
  final int topK;

  /// Temporal decay lambda. Higher = faster decay with age.
  /// Score multiplied by `exp(-temporalDecayLambda * ageDays)`.
  final double temporalDecayLambda;

  /// Vector cosine noise floor.
  ///
  /// Real embedding models score unrelated text well above zero
  /// (~0.1–0.3 cosine depending on the model). Similarities at or below
  /// the floor contribute nothing; above it the signal is rescaled to
  /// [0, 1] via `(cos - floor) / (1 - floor)`. This lets
  /// [relevanceThreshold] filter genuine junk instead of compensating
  /// for the embedding model's score distribution. Set to 0 to disable.
  ///
  /// The floor is a property of the embedding model — calibrate it when
  /// switching models (eval-validated: `all-minilm` ≈ 0.2 (the default),
  /// `nomic-embed-text` ≈ 0.4).
  final double vectorNoiseFloor;

  const RecallConfig({
    this.ftsWeight = 1.0,
    this.vectorWeight = 1.5,
    this.entityWeight = 0.8,
    this.componentWeights = const {},
    this.categoryWeights = const {},
    this.excludeComponents = const {},
    this.relevanceThreshold = 0.05,
    this.topK = 20,
    this.temporalDecayLambda = 0.005,
    this.vectorNoiseFloor = 0.2,
  });

  /// Copy with selected fields replaced — the ergonomic base for per-call
  /// overrides and profile derivation.
  RecallConfig copyWith({
    double? ftsWeight,
    double? vectorWeight,
    double? entityWeight,
    Map<String, double>? componentWeights,
    Map<String, double>? categoryWeights,
    Set<String>? excludeComponents,
    double? relevanceThreshold,
    int? topK,
    double? temporalDecayLambda,
    double? vectorNoiseFloor,
  }) {
    return RecallConfig(
      ftsWeight: ftsWeight ?? this.ftsWeight,
      vectorWeight: vectorWeight ?? this.vectorWeight,
      entityWeight: entityWeight ?? this.entityWeight,
      componentWeights: componentWeights ?? this.componentWeights,
      categoryWeights: categoryWeights ?? this.categoryWeights,
      excludeComponents: excludeComponents ?? this.excludeComponents,
      relevanceThreshold: relevanceThreshold ?? this.relevanceThreshold,
      topK: topK ?? this.topK,
      temporalDecayLambda: temporalDecayLambda ?? this.temporalDecayLambda,
      vectorNoiseFloor: vectorNoiseFloor ?? this.vectorNoiseFloor,
    );
  }
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
  ///
  /// [config] overrides the instance default for this call only — the
  /// hook for query-adaptive weighting (see RecallProfiles).
  Future<RecallResult> recall(
    String query, {
    int budgetTokens = 4000,
    RecallConfig? config,
  }) async {
    final cfg = config ?? _config;
    final excluded = cfg.excludeComponents;

    // 1. Gather candidates from all signals.
    final candidates = <String, _Candidate>{};

    // Signal 1: full-text search across all memories. FtsMatch.score is
    // the store's normalized [0, 1] absolute relevance — a weak best-match
    // stays weak rather than being inflated to 1.0 by max-normalization.
    final ftsResults = await _store.searchFts(query, limit: 50);
    for (final m in ftsResults) {
      if (excluded.contains(m.memory.component)) continue;
      _getOrCreate(candidates, m.memory).ftsScore = m.score.clamp(0.0, 1.0);
    }

    // Signal 2: Vector similarity (if embeddings available).
    if (_embeddings != null) {
      final queryVec = await _embeddings!.embed(query);
      final embedded = await _store.loadActiveWithEmbeddings();
      for (final mem in embedded) {
        if (excluded.contains(mem.component)) continue;
        final sim = cosineSimilarity(queryVec, mem.embedding!);
        if (sim > 0) {
          _getOrCreate(candidates, mem).vectorScore = sim;
        }
      }
    }

    // Signal 3: Entity graph expansion.
    await _entityGraphExpansion(query, candidates, excluded);

    if (candidates.isEmpty) return const RecallResult(items: []);

    // 2. Fuse signals into final score.
    final floor = cfg.vectorNoiseFloor;
    for (final c in candidates.values) {
      // Noise-floored vector signal; c.vectorScore keeps the raw cosine
      // for the ScoredRecall signal breakdown.
      final vector = floor > 0
          ? math.max(0.0, (c.vectorScore - floor) / (1.0 - floor))
          : c.vectorScore;

      final rawScore = (cfg.ftsWeight * c.ftsScore) +
          (cfg.vectorWeight * vector) +
          (cfg.entityWeight * c.entityScore);

      // Component and category weights.
      final componentWeight = cfg.componentWeights[c.memory.component] ?? 1.0;
      final categoryWeight = cfg.categoryWeights[c.memory.category] ?? 1.0;

      // Importance multiplier.
      final importance = c.memory.importance;

      // Temporal decay.
      final ageDays =
          DateTime.now().difference(c.memory.updatedAt).inHours / 24.0;
      final decay = math.exp(-cfg.temporalDecayLambda * math.max(0, ageDays));

      // Access frequency boost (logarithmic).
      final accessBoost = 1 + math.log(1 + c.memory.accessCount) * 0.1;

      c.finalScore = rawScore *
          componentWeight *
          categoryWeight *
          importance *
          decay *
          accessBoost;
    }

    // 3. Filter by relevance threshold.
    candidates.removeWhere((_, c) => c.finalScore < cfg.relevanceThreshold);

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
    final limited = deduped.take(cfg.topK).toList();

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
    Set<String> excludedComponents,
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
      if (excludedComponents.contains(mem.component)) continue;
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

}

class _Candidate {
  final StoredMemory memory;
  double ftsScore = 0;
  double vectorScore = 0;
  double entityScore = 0;
  double finalScore = 0;

  _Candidate({required this.memory});
}
