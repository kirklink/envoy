# Souvenir v3 — Unified Recall Architecture

Redesign of Souvenir's recall pipeline from per-component independent recall to
a single unified index queried once per turn. Consolidation remains
component-based. This document supersedes v2's recall pathway while preserving
its consolidation architecture. All phases are implemented and verified — see
[Implementation Status](#implementation-status) for evaluation results.

**Motivation**: Experiments in `experiment-log.md` demonstrated that
per-component recall fundamentally cannot surface a strong single-signal match
over weak multi-signal noise, regardless of tuning.

---

## Problem Statement

Souvenir v2's recall architecture has each `MemoryComponent` independently query
its own private store and return top-K results. The `Mixer` then combines these
per-component result sets into a final ranking. This creates three problems
observed in the Memory Lab experiments:

### 1. Component boundary is orthogonal to query relevance

A query about "favourite animal" should find the durable memory "User finds
rabbits cute" — but the component boundary means this memory competes only
against other durable memories for inclusion in durable's top-K. Meanwhile,
task and environmental components return their own top-K items (about Dart
functions), which are irrelevant to the query but guaranteed to appear because
each component always returns _something_.

The result: 10 items recalled, 7 irrelevant, because each component fills its
quota independently of query relevance.

### 2. RRF discards score magnitude

DurableMemory uses RRF (Reciprocal Rank Fusion) to combine BM25, entity graph,
and vector signals. RRF converts scores to ranks, then computes
`1/(rank + k)`. This means:

- A cosine similarity of 0.37 (strong match) and 0.01 (noise) become rank
  positions, losing the 37x magnitude difference
- A memory appearing in 1 signal (vector only) can never beat one appearing
  in 3 signals (BM25 + entity graph + weak vector), regardless of how strong
  the single signal is

Experiments confirmed this: lowering `rrfK` from 60 to 10 _widened_ the gap
because it amplified the multi-signal advantage.

### 3. Score normalization across incompatible scales

Each component uses a different scoring algorithm (RRF, Jaccard, BM25). The
mixer normalizes by dividing by each component's max score, but this normalizes
within noise — if all durable results are irrelevant, the least-irrelevant one
still gets a normalized score of 1.0.

---

## Design Principles

1. **Consolidation stays component-based.** Different memory types need different
   extraction prompts, merge strategies, decay curves, and lifecycle rules.
   Components are the right abstraction for _writing_ memories.

2. **Recall is unified.** A single query searches all memories in one index.
   Component type becomes metadata on the result, not a search boundary.

3. **Score magnitude is preserved.** Use weighted scoring where signal strengths
   contribute directly, not RRF ranks.

4. **Silence is an option.** If no memories are relevant to a query, return
   nothing. Components should not pad their top-K with noise.

5. **Budget enforces quality, not quota.** Token budget caps total recall, but
   there's no per-component minimum. If all relevant results are durable
   memories, that's fine.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Souvenir Engine                         │
│                                                             │
│  ┌──────────────┐    ┌──────────────────────────────┐       │
│  │ EpisodeBuffer│───→│  Consolidation Trigger        │       │
│  │  (unchanged) │    └──────────┬───────────────────┘       │
│  └──────────────┘               │                           │
│                    episodes exposed to all components        │
│                                 │                           │
│          ┌──────────────────────┼──────────────────┐        │
│          ▼                      ▼                  ▼        │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐    │
│  │ TaskMemory   │   │ Environmental│   │ DurableMemory│    │
│  │ (component)  │   │ Memory       │   │ (component)  │    │
│  │              │   │ (component)  │   │              │    │
│  └──────┬───────┘   └──────┬───────┘   └──────┬───────┘    │
│         │  consolidate()    │                  │             │
│         └──────────┬────────┘──────────────────┘             │
│                    ▼                                        │
│          ┌──────────────────┐                                │
│          │   MemoryStore    │ ← unified storage              │
│          │  (FTS5 + vec)    │                                │
│          └────────┬─────────┘                                │
│                   │                                         │
│            recall(query)                                    │
│                   │                                         │
│          ┌────────▼─────────┐                                │
│          │  UnifiedRecall   │ ← single query, all memories   │
│          │  FTS5 + cosine   │                                │
│          │  + score fusion  │                                │
│          └────────┬─────────┘                                │
│                   ▼                                         │
│           Ranked context                                    │
│            for prompt                                       │
└─────────────────────────────────────────────────────────────┘
```

### Key Change

In v2, each component owned its own store and recall pipeline. In v3:

- Components **write** to a shared `MemoryStore` during consolidation
- The engine **reads** from the unified store during recall
- Components no longer implement `recall()` — recall is the engine's job

---

## Core Interfaces

### MemoryComponent (revised)

Components lose the `recall()` method. They only consolidate.

```dart
abstract class MemoryComponent {
  /// Unique name (e.g., 'task', 'durable', 'environmental').
  String get name;

  /// Initialize component-specific state.
  Future<void> initialize();

  /// Extract and store memories from episodes.
  ///
  /// Writes to the shared [MemoryStore] via the store reference
  /// provided at construction. Each stored item is tagged with
  /// this component's [name].
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
  );

  /// Cleanup.
  Future<void> close();
}
```

**Note**: `ComponentBudget` is removed from `consolidate()`. Budget was only
meaningful for recall; components don't need a token budget during extraction.
Components that have item caps (TaskMemory's `maxItemsPerSession`) enforce
those via their own config, not via token budget.

### StoredMemory (unified)

All memories from all components live in one table/index. The `component` field
is metadata, not a partition.

```dart
/// Status of a stored memory.
enum MemoryStatus {
  /// Active and eligible for recall.
  active,

  /// Replaced by a newer memory (contradiction resolution).
  superseded,

  /// Session-scoped item expired at session boundary or capacity eviction.
  expired,

  /// Importance decayed below floor threshold.
  decayed,
}

class StoredMemory {
  /// Unique ID (ULID).
  final String id;

  /// The memory content — a standalone, self-contained statement.
  final String content;

  /// Which component created this memory (e.g., 'task', 'durable',
  /// 'environmental').
  final String component;

  /// Component-specific category (e.g., 'goal', 'fact', 'capability').
  final String category;

  /// Importance score (0.0–1.0). Set by the component at creation.
  final double importance;

  /// Session that produced this memory. Null for cross-session memories
  /// (durable, environmental).
  final String? sessionId;

  /// IDs of source episodes that contributed to this memory.
  final List<String> sourceEpisodeIds;

  /// Embedding vector. Null until generated by the engine post-consolidation.
  final List<double>? embedding;

  /// IDs of entities referenced by this memory.
  final List<String> entityIds;

  /// When this memory was first created.
  final DateTime createdAt;

  /// When this memory was last modified.
  final DateTime updatedAt;

  /// When this memory was last recalled.
  final DateTime? lastAccessed;

  /// Number of times this memory has been recalled.
  final int accessCount;

  /// Current lifecycle status.
  final MemoryStatus status;

  /// When this memory became valid. Null means valid since [createdAt].
  final DateTime? validAt;

  /// When this memory became invalid. Null means still valid.
  final DateTime? invalidAt;

  /// ID of the memory that superseded this one.
  final String? supersededBy;

  /// Whether this memory is currently active and temporally valid.
  bool get isActive {
    if (status != MemoryStatus.active) return false;
    final now = DateTime.now().toUtc();
    if (validAt != null && now.isBefore(validAt!)) return false;
    if (invalidAt != null && now.isAfter(invalidAt!)) return false;
    return true;
  }
}
```

### MemoryStore (unified)

One store, one FTS5 index, one embedding space.

```dart
/// A memory with its BM25 relevance score from full-text search.
class FtsMatch {
  /// The matched memory.
  final StoredMemory memory;

  /// BM25 relevance score (higher = more relevant).
  final double score;
}

abstract class MemoryStore {
  /// Initialize storage (create tables, indexes).
  Future<void> initialize();

  /// Insert a memory. Component sets all fields including [component] tag.
  Future<void> insert(StoredMemory memory);

  /// Partially update a memory by ID. Only non-null fields are updated.
  /// Always bumps [StoredMemory.updatedAt].
  Future<void> update(String id, {
    String? content,
    double? importance,
    List<String>? entityIds,
    List<double>? embedding,
    String? status,
    String? supersededBy,
    DateTime? invalidAt,
    List<String>? sourceEpisodeIds,
  });

  /// Find active memories similar to [content] within [component].
  ///
  /// Used during consolidation for merge detection. Scoped to component
  /// because merge logic is component-specific (task items merge differently
  /// than durable facts). Optionally filtered by [category] and [sessionId].
  Future<List<StoredMemory>> findSimilar(
    String content,
    String component, {
    String? category,
    String? sessionId,
    int limit = 5,
  });

  /// Full-text search across ALL active memories.
  ///
  /// Returns memories ranked by BM25 relevance. No component filter — this
  /// is the unified recall path.
  Future<List<FtsMatch>> searchFts(String query, {int limit = 50});

  /// Load all active memories that have embeddings.
  ///
  /// Filtered to status = 'active' and temporally valid.
  Future<List<StoredMemory>> loadActiveWithEmbeddings();

  /// Load all active memories without embeddings.
  ///
  /// Used by the engine to generate embeddings post-consolidation.
  Future<List<StoredMemory>> findUnembeddedMemories({int limit = 100});

  // ── Entity graph ────────────────────────────────────────────────

  /// Upsert an entity (insert or update by name).
  Future<void> upsertEntity(Entity entity);

  /// Upsert a relationship (insert or update by composite key).
  Future<void> upsertRelationship(Relationship rel);

  /// Find entities whose name matches [query] (case-insensitive substring).
  Future<List<Entity>> findEntitiesByName(String query);

  /// Find all relationships involving [entityId].
  Future<List<Relationship>> findRelationshipsForEntity(String entityId);

  /// Find active memories associated with any of the given entity IDs.
  Future<List<StoredMemory>> findMemoriesByEntityIds(List<String> entityIds);

  // ── Lifecycle operations ────────────────────────────────────────

  /// Bump access_count and last_accessed for the given memory IDs.
  Future<void> updateAccessStats(List<String> ids);

  /// Decay importance for memories in [component] not accessed within
  /// [inactivePeriod]. Items falling below [floorThreshold] are marked
  /// as decayed. Returns the number of items that crossed the floor.
  Future<int> applyImportanceDecay({
    required String component,
    required Duration inactivePeriod,
    required double decayRate,
    double? floorThreshold,
  });

  /// Expire all active memories for [sessionId] in [component].
  Future<int> expireSession(String sessionId, String component);

  /// Expire a single memory by ID.
  Future<void> expireItem(String id);

  /// Mark a memory as superseded by another.
  Future<void> supersede(String oldId, String newId);

  /// Count active memories in [component], optionally filtered by
  /// [sessionId].
  Future<int> activeItemCount(String component, {String? sessionId});

  /// Return active memories for [sessionId] in [component].
  Future<List<StoredMemory>> activeItemsForSession(
    String sessionId,
    String component,
  );

  /// Cleanup.
  Future<void> close();
}
```

### UnifiedRecall

The recall pipeline lives in the engine, not in components. It queries the
unified store with multiple signals and fuses them using weighted scoring
(not RRF).

```dart
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
```

### Score Fusion

Replace RRF with **weighted linear combination** of normalized signal scores.
This preserves magnitude:

```
rawScore     = (ftsWeight × ftsScore_norm)
             + (vectorWeight × cosineSimilarity)
             + (entityWeight × entityScore_norm)

finalScore   = rawScore
             × componentWeight
             × importanceMultiplier
             × temporalDecay
             × accessBoost
```

Where:
- `ftsScore_norm` = BM25 score normalized to [0, 1] by dividing by max BM25
  score in the result set (0 if empty)
- `cosineSimilarity` = raw cosine similarity (already in [0, 1] for normalized
  embeddings)
- `entityScore_norm` = 1.0 if directly mentioned, confidence score if 1-hop
  related, 0 if not in entity graph
- `componentWeight` = per-component multiplier from `RecallConfig`
- `importanceMultiplier` = memory's importance score (0.0 - 1.0)
- `temporalDecay` = `exp(-λ × ageDays)` where λ = `temporalDecayLambda`
  (configurable, default 0.005); age is measured from `updatedAt`
- `accessBoost` = `1 + log(1 + accessCount) × 0.1` — frequently recalled
  memories get a small logarithmic boost (e.g., 10 accesses → ~1.24×)

**Why not RRF**: RRF is designed for merging results from heterogeneous
retrieval systems where score distributions are incompatible. Our signals
(BM25, cosine, entity graph) can all be meaningfully normalized to [0, 1], so
weighted combination preserves magnitude while RRF destroys it.

**Relevance threshold**: A memory must score above `relevanceThreshold` after
all weighting to be included. This means irrelevant turns return empty recall
rather than padding with noise. The threshold is intentionally low (0.05) — it
filters junk, not borderline results.

---

## Souvenir Engine (revised)

```dart
class Souvenir {
  final List<MemoryComponent> components;
  final MemoryStore store;
  final UnifiedRecall _recall;
  final EmbeddingProvider? _embeddings;
  final EpisodeStore _episodeStore;
  final int _defaultBudgetTokens;

  /// Creates a Souvenir v3 engine.
  ///
  /// [store] is the shared memory store all components write to.
  /// [recallConfig] controls signal weights, thresholds, and decay.
  /// [embeddings] is optional — when provided, the engine generates
  /// embeddings for new memories after each consolidation.
  Souvenir({
    required this.components,
    required this.store,
    EpisodeStore? episodeStore,
    RecallConfig recallConfig = const RecallConfig(),
    EmbeddingProvider? embeddings,
    Tokenizer tokenizer = const ApproximateTokenizer(),
    int defaultBudgetTokens = 4000,
  });

  /// Initializes the shared store and all components concurrently.
  Future<void> initialize() async {
    await store.initialize();
    await Future.wait(components.map((c) => c.initialize()));
  }

  /// Record, flush — unchanged from v2.
  Future<void> record(Episode episode);
  Future<void> flush();

  /// Consolidates unconsolidated episodes across all components.
  ///
  /// 1. Flushes the buffer.
  /// 2. Fetches unconsolidated episodes from the episode store.
  /// 3. Passes them to all components concurrently (components write to
  ///    the shared store).
  /// 4. Marks episodes consolidated.
  /// 5. Generates embeddings for any unembedded memories.
  Future<List<ConsolidationReport>> consolidate(LlmCallback llm) async {
    await flush();
    final episodes = await _episodeStore.fetchUnconsolidated();
    if (episodes.isEmpty) return [];

    final reports = await Future.wait(
      components.map((c) => c.consolidate(episodes, llm)),
    );
    await _episodeStore.markConsolidated(episodes);

    // Post-consolidation: generate embeddings for new memories.
    if (_embeddings != null) {
      await _generateEmbeddings();
    }
    return reports;
  }

  /// Unified recall — delegates to [UnifiedRecall].
  Future<RecallResult> recall(String query, {int? budgetTokens}) async {
    return _recall.recall(
      query,
      budgetTokens: budgetTokens ?? _defaultBudgetTokens,
    );
  }

  /// Generates embeddings for memories that don't have them yet.
  Future<void> _generateEmbeddings() async {
    final unembedded = await store.findUnembeddedMemories();
    for (final mem in unembedded) {
      try {
        final vector = await _embeddings!.embed(mem.content);
        await store.update(mem.id, embedding: vector);
      } catch (_) {
        // Embedding failure is non-fatal — the memory is still searchable
        // via FTS and entity graph signals.
      }
    }
  }
}
```

The recall pipeline itself lives in `UnifiedRecall`, not the engine:

```dart
class UnifiedRecall {
  Future<RecallResult> recall(String query, {int budgetTokens = 4000}) async {
    final candidates = <String, _Candidate>{};

    // 1. FTS5 BM25 across all active memories.
    final ftsResults = await store.searchFts(query, limit: 50);
    // Normalize BM25 to [0, 1] by dividing by max score.
    for (final m in ftsResults) {
      _getOrCreate(candidates, m.memory).ftsScore = m.score / maxBm25;
    }

    // 2. Vector similarity (if embeddings available).
    if (embeddings != null) {
      final queryVec = await embeddings!.embed(query);
      final embedded = await store.loadActiveWithEmbeddings();
      for (final mem in embedded) {
        final sim = _cosineSimilarity(queryVec, mem.embedding!);
        if (sim > 0) _getOrCreate(candidates, mem).vectorScore = sim;
      }
    }

    // 3. Entity graph expansion (direct + 1-hop).
    await _entityGraphExpansion(query, candidates);

    // 4. Fuse signals: weighted sum × component × importance × decay × access.
    for (final c in candidates.values) {
      final rawScore = (ftsWeight * c.ftsScore)
                     + (vectorWeight * c.vectorScore)
                     + (entityWeight * c.entityScore);
      final componentWeight = componentWeights[c.memory.component] ?? 1.0;
      final decay = exp(-temporalDecayLambda * ageDays);
      final accessBoost = 1 + log(1 + c.memory.accessCount) * 0.1;
      c.finalScore = rawScore * componentWeight * c.memory.importance
                   * decay * accessBoost;
    }

    // 5. Filter by relevance threshold.
    candidates.removeWhere((_, c) => c.finalScore < relevanceThreshold);

    // 6. Sort descending, deduplicate by content, take topK.
    // 7. Budget-aware cutoff (always includes at least one item).
    // 8. Update access stats for recalled memories.
    return RecallResult(items: selected);
  }
}
```

### RecallResult

`RecallResult`, `ScoredRecall`, `RecallConfig`, and `UnifiedRecall` all live in
`recall.dart`.

```dart
class RecallResult {
  /// Ranked memories with scores.
  final List<ScoredRecall> items;

  /// Total tokens consumed.
  int get totalTokens => items.fold(0, (sum, i) => sum + i.tokens);
}

class ScoredRecall {
  final String id;
  final String content;
  final String component;
  final String category;
  final double score;
  final int tokens;

  /// Raw signal strengths (before weighting) for observability.
  final double ftsSignal;
  final double vectorSignal;
  final double entitySignal;
}
```

The signal breakdown enables the dashboard to show _why_ each memory was
recalled, which is critical for tuning. Example from evaluation:

```
"User thinks rabbits are the most adorable creatures"
Score: 1.348
FTS: 0.00 (no keyword match for "favourite animal")
Vec: 1.00 (semantic bridge via embedding similarity)
Entity: 0.00 (no entity link)
```

---

## Component Adaptations

### TaskMemory

- **Consolidation**: Writes `StoredMemory` to the shared store with
  `component: 'task'`, `category: 'goal'|'decision'|'result'|'context'`,
  and `sessionId`.
- **Merge detection**: Uses `store.findSimilar(content, 'task', sessionId: ...)`
  — scoped to task component within current session.
- **Session expiry**: Uses `store.expireSession(sessionId, 'task')` at session
  boundary.
- **Max items**: Uses `store.activeItemCount('task', sessionId: ...)`
  and `store.expireItem()` for cap enforcement.
- **No recall method** — removed.

### EnvironmentalMemory

- **Consolidation**: Writes to shared store with `component: 'environmental'`,
  `category: 'capability'|'constraint'|'environment'|'pattern'`.
- **Merge detection**: `store.findSimilar(content, 'environmental')`.
- **Decay**: `store.applyImportanceDecay(component: 'environmental', ...)`.
- **No recall method** — removed.

### DurableMemory

- **Consolidation**: Writes to shared store with `component: 'durable'`,
  `category: 'fact'|'preference'|'knowledge'`.
- **Entity graph**: Writes entities and relationships to shared store.
  Entity graph is shared across all components (an entity mentioned in a task
  context and in a durable fact should be the same entity node).
- **Embeddings**: Generated during consolidation and stored on the
  `StoredMemory`. The engine uses these during recall.
- **Merge/conflict**: Uses `store.findSimilar(content, 'durable')` for
  duplicate detection, LLM for contradiction resolution.
- **No recall method** — removed. BM25, entity graph, and vector search
  all move to the engine's unified recall.

### Embedding Generation

In v2, only DurableMemory generated embeddings. In v3, the engine can
generate embeddings for any memory during consolidation:

```dart
// In Souvenir.consolidate(), after component consolidation:
if (embeddings != null) {
  final unembedded = await store.findUnembeddedMemories();
  for (final mem in unembedded) {
    try {
      final vector = await embeddings!.embed(mem.content);
      await store.update(mem.id, embedding: vector);
    } catch (_) {
      // Non-fatal — memory is still searchable via FTS5 and entity graph.
    }
  }
}
```

This means task and environmental memories also get vector embeddings, making
them findable via semantic search alongside durable memories.

---

## Storage Schema

One table for all memories, one FTS5 index, entity tables shared:

```sql
CREATE TABLE memories (
  id             TEXT PRIMARY KEY,
  content        TEXT NOT NULL,
  component      TEXT NOT NULL,        -- 'task', 'durable', 'environmental'
  category       TEXT NOT NULL,        -- 'goal', 'fact', 'capability', etc.
  importance     REAL NOT NULL DEFAULT 0.5,
  session_id     TEXT,                 -- null for cross-session memories
  source_ids     TEXT,                 -- JSON array of episode IDs
  entity_ids     TEXT,                 -- JSON array of entity IDs
  embedding      BLOB,                -- Float32 vector (null until generated)
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  last_accessed  TEXT,
  access_count   INTEGER NOT NULL DEFAULT 0,
  status         TEXT NOT NULL DEFAULT 'active',
  superseded_by  TEXT,
  valid_at       TEXT,
  invalid_at     TEXT
);

CREATE VIRTUAL TABLE memories_fts USING fts5(
  content,
  content='memories',
  content_rowid='rowid'
);

-- Triggers to keep FTS5 in sync.

CREATE TABLE entities (
  id    TEXT PRIMARY KEY,
  name  TEXT NOT NULL UNIQUE,
  type  TEXT NOT NULL
);

CREATE TABLE relationships (
  from_entity TEXT NOT NULL,
  to_entity   TEXT NOT NULL,
  relation    TEXT NOT NULL,
  confidence  REAL NOT NULL DEFAULT 1.0,
  updated_at  TEXT NOT NULL,
  PRIMARY KEY (from_entity, to_entity, relation)
);
```

Multi-agent prefix applied to all table names via `SouvenirCellar`, same as v2.

---

## What Changes from v2

| Aspect | v2 | v3 |
|--------|----|----|
| Recall ownership | Each component | Engine (unified) |
| Storage | Per-component stores | Single shared store |
| Scoring | RRF within durable, Jaccard in task/env, normalize in mixer | Weighted linear combination across all memories |
| Embeddings | Durable only | All memories |
| Component `recall()` | Required | Removed |
| Mixer | Cross-component score normalization | Replaced by `RecallConfig` |
| Budget model | Per-component allocation | Global total (no per-component quota) |
| Empty recall | Never (each component returns top-K) | Possible (threshold filters noise) |
| FTS5 indexes | Per-component (durable FTS5, task Jaccard, env Jaccard) | Single FTS5 across all memories |
| Entity graph | Durable only | Shared across all components |

## What Stays the Same

- Episode recording and flush
- `MemoryComponent` as the consolidation unit
- Component-specific extraction prompts and merge strategies
- Component-specific decay curves and lifecycle rules
- `EpisodeStore` for episode persistence
- `EmbeddingProvider` interface (Ollama, etc.)
- `SouvenirCellar` factory pattern (multi-agent prefix, encryption)
- `ConsolidationReport` structure
- `LlmCallback` typedef
- `Tokenizer` for budget accounting

---

## Budget Model

v2 used per-component token allocations. v3 simplifies to a global budget:

```dart
class Budget {
  final int totalTokens;
  final Tokenizer tokenizer;
}
```

Per-component allocation is no longer needed because recall is unified. The
`RecallConfig.componentWeights` control how much each component _contributes_
to the ranking, but budget is a single global cap on total tokens returned.

Component weights in `RecallConfig` can achieve the same effect as budget
allocation: if you want more durable content, increase its weight — it'll rank
higher and consume more of the global budget naturally.

---

## Expected Outcome for "Favourite Animal" Query

With unified recall and weighted scoring:

1. **FTS5**: "favourite animal" matches nothing (no keyword overlap with
   "rabbits") → ftsScore = 0 for all memories
2. **Vector**: "favourite animal" → cosine 0.37 with "rabbits cute", 0.01
   with Dart memories → vectorScore heavily favors rabbits
3. **Entity graph**: no entity match → entityScore = 0

With `vectorWeight = 1.5`:
- Rabbits: `0 + 1.5 × 0.37 + 0 = 0.555` × importance × decay
- Dart:    `0 + 1.5 × 0.01 + 0 = 0.015` × importance × decay

Even with Dart importance at 0.80 and rabbits at 0.40:
- Rabbits: `0.555 × 0.40 = 0.222`
- Dart:    `0.015 × 0.80 = 0.012`

Rabbits scores **18.5x** higher. In v2 with RRF, Dart scored 3.8x higher.

---

## Implementation Status

All phases complete. See `eval/` for full evaluation reports.

### Phase 1: Unified MemoryStore — Complete

- `StoredMemory` model with `MemoryStatus` enum and `isActive` getter
- `MemoryStore` abstract interface
- `InMemoryMemoryStore` implementation (for tests)
- `SqliteMemoryStore` implementation (single table + FTS5 + entity tables)

### Phase 2: Unified Recall — Complete

- `RecallConfig` with signal weights, component weights, decay lambda
- Score fusion: weighted linear combination (magnitude-preserving)
- Vector search via `EmbeddingProvider`
- Entity graph expansion (direct + 1-hop with confidence)
- Relevance threshold filtering
- Budget-aware trimming (always includes at least one item)
- `RecallResult` / `ScoredRecall` with signal breakdown

### Phase 3: Component Adaptation — Complete

- `MemoryComponent` revised: `recall()` removed, `ComponentBudget` removed
- TaskMemory, EnvironmentalMemory, DurableMemory adapted to shared store
- Embedding generation moved to engine post-consolidation

### Phase 4: Engine Integration — Complete

- `Souvenir` engine delegates recall to `UnifiedRecall`
- `Mixer` removed (replaced by `RecallConfig` + score fusion)
- `Budget` simplified to global token cap
- `SouvenirCellar` factory updated for unified store

### Phase 5: Automated Recall Quality Tests — Complete

590-line test suite (`test/recall_test.dart`) covering:
- Basic recall, vector recall, entity graph recall
- Score fusion, component weights, importance multiplier
- Relevance threshold, budget trimming
- The "rabbit test" (semantic bridging with no keyword overlap)

### Phase 6: Legacy Cleanup — Complete

- Per-component stores removed
- `SouvenirCellar` migrated to unified store factory

### Phase 7: Evaluation Harness — Complete

Grid search over 120 weight combinations. Results in `eval/tune.md`.

**Evaluation summary (18 scenarios, 8 categories):**

| Scenario | Queries | Pass | MRR |
|---|---|---|---|
| semantic_bridge | 3 | 3/3 | 1.00 |
| fts_direct | 3 | 3/3 | 1.00 |
| entity_expansion | 2 | 2/2 | 1.00 |
| multi_signal | 2 | 2/2 | 1.00 |
| component_weights | 1 | 1/1 | 1.00 |
| temporal_decay | 1 | 1/1 | 1.00 |
| relevance_silence | 2 | 2/2 | 1.00 |
| conversation_pipeline | 4 | 4/4 | 1.00 |
| **TOTAL** | **18** | **18/18** | **1.00** |

Both the default config (`fts=1.0, vec=1.5, entity=0.8`) and the tuned config
(`fts=0.5, vec=0.5, entity=0.3`) achieve perfect scores on the evaluation
suite. The defaults are retained as they provide better score separation
between relevant and irrelevant results.

---

## Design Decisions (Resolved)

These were open questions during design; all resolved during implementation.

### Entity Graph Ownership

**Decision: DurableMemory only.** Entity extraction stays in DurableMemory.
The entity graph is stored in the shared `MemoryStore` and queried during
unified recall against all memories — so a task memory linked to an entity
(via `entityIds`) benefits from entity graph expansion even though task
consolidation doesn't extract entities. This avoids the LLM cost of entity
extraction in task/environmental consolidation while still enabling cross-
component entity recall.

### Importance Assignment Across Components

**Decision: No explicit calibration.** Components assign importance
independently via their extraction prompts. Component weights in `RecallConfig`
handle cross-component calibration at recall time — e.g., a durable memory at
importance 0.40 with `componentWeight: 1.5` effectively scores as 0.60. The
evaluation harness confirmed this approach works: durable facts at importance
0.7 consistently outrank environmental observations at 0.6 for the same topic,
without explicit calibration.

### Embedding All Memories

**Decision: Embed all.** The engine generates embeddings for all unembedded
memories after each consolidation (see `_generateEmbeddings()` in the engine).
Embedding failures are non-fatal — the memory remains searchable via FTS and
entity graph. This is the key enabler for semantic bridging across component
boundaries (e.g., "favourite animal" → task memory about rabbits).

### Session-Scoped Recall Filtering

**Decision: Store-level filtering.** Both `searchFts()` and
`loadActiveWithEmbeddings()` filter to `status = 'active'` and temporally
valid (`invalid_at IS NULL OR invalid_at > now`). Expired and superseded
memories are excluded from recall automatically. The `StoredMemory.isActive`
getter provides the same check in Dart code.

---

## Relationship to v2 Codebase

This was a **new implementation**, not a refactor of v2:

- `MemoryStore` replaced per-component stores
- Components rewritten to use the shared store
- Engine recall logic replaced Mixer + per-component recall
- Per-component stores, Mixer, and labeled recall classes removed

### File Layout (v3)

```
lib/src/
  engine.dart                          ← Souvenir v3 engine (coordinator)
  recall.dart                          ← UnifiedRecall, RecallConfig, ScoredRecall, RecallResult
  memory_store.dart                    ← MemoryStore interface + FtsMatch
  stored_memory.dart                   ← StoredMemory, MemoryStatus, Entity, Relationship
  in_memory_memory_store.dart          ← In-memory MemoryStore (for tests)
  sqlite_memory_store.dart             ← SQLite/FTS5 MemoryStore
  souvenir_cellar.dart                 ← Factory: multi-agent prefix + encryption
  memory_component.dart                ← MemoryComponent interface + ConsolidationReport
  episode_store.dart                   ← EpisodeStore interface + InMemoryEpisodeStore
  cellar_episode_store.dart            ← SQLite EpisodeStore
  embedding_provider.dart              ← EmbeddingProvider interface
  ollama_embedding_provider.dart       ← Ollama embedding implementation
  llm_callback.dart                    ← LlmCallback typedef
  tokenizer.dart                       ← Tokenizer interface + ApproximateTokenizer
  models/episode.dart                  ← Episode model
  task/task_memory.dart                ← TaskMemory component
  task/task_memory_config.dart         ← TaskMemory configuration
  durable/durable_memory.dart          ← DurableMemory component
  durable/durable_memory_config.dart   ← DurableMemory configuration
  environmental/environmental_memory.dart       ← EnvironmentalMemory component
  environmental/environmental_memory_config.dart ← EnvironmentalMemory configuration
  eval/                                ← Evaluation harness (runner, scenarios, report)
```

### Files Removed from v2

```
mixer.dart                                    ← replaced by RecallConfig + score fusion
labeled_recall.dart                           ← replaced by ScoredRecall
durable/durable_memory_store.dart             ← merged into unified MemoryStore
task/task_memory_store.dart                   ← merged into unified MemoryStore
task/cellar_task_memory_store.dart            ← merged into unified MemoryStore
environmental/environmental_memory_store.dart ← merged into unified MemoryStore
environmental/cellar_environmental_memory_store.dart ← merged into unified MemoryStore
```
