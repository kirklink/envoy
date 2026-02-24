# Souvenir v3 — Unified Recall Architecture

Redesign of Souvenir's recall pipeline from per-component independent recall to
a single unified index queried once per turn. Consolidation remains
component-based. This spec supersedes v2's recall pathway while preserving its
consolidation architecture.

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
class StoredMemory {
  /// Unique ID (ULID).
  final String id;

  /// The memory content (human-readable text).
  final String content;

  /// Which component created this memory.
  final String component;

  /// Component-specific category (e.g., 'goal', 'fact', 'capability').
  final String category;

  /// Importance score (0.0 - 1.0). Set by the component at creation.
  final double importance;

  /// Session that produced this memory (null for cross-session memories).
  final String? sessionId;

  /// Episode IDs that contributed to this memory.
  final List<String> sourceEpisodeIds;

  /// Embedding vector (null if not yet generated).
  final List<double>? embedding;

  /// Entity IDs linked to this memory (for entity graph queries).
  final List<String> entityIds;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastAccessed;
  final int accessCount;

  /// Status: active, expired, decayed, superseded.
  final String status;

  /// Temporal validity.
  final DateTime? validAt;
  final DateTime? invalidAt;

  /// For contradiction chains.
  final String? supersededBy;
}
```

### MemoryStore (unified)

One store, one FTS5 index, one embedding space.

```dart
abstract class MemoryStore {
  /// Insert a memory. Component sets all fields including [component] tag.
  Future<void> insert(StoredMemory memory);

  /// Update a memory by ID.
  Future<void> update(String id, {
    String? content,
    double? importance,
    List<String>? entityIds,
    List<double>? embedding,
    String? status,
    String? supersededBy,
    DateTime? invalidAt,
  });

  /// Find memories similar to [content] within [component].
  ///
  /// Used during consolidation for merge detection. Scoped to component
  /// because merge logic is component-specific (task items merge differently
  /// than durable facts).
  Future<List<StoredMemory>> findSimilar(
    String content,
    String component, {
    String? category,
    String? sessionId,
    int limit = 5,
  });

  /// Full-text search across ALL memories (no component filter).
  Future<List<ScoredMemory>> searchFts(String query, {int limit = 50});

  /// Load all memories with embeddings for vector search.
  ///
  /// Filtered to status = 'active' and non-expired.
  Future<List<StoredMemory>> loadActiveWithEmbeddings();

  /// Entity graph operations.
  Future<void> upsertEntity(Entity entity);
  Future<void> upsertRelationship(Relationship rel);
  Future<List<Entity>> findEntitiesByName(String query);
  Future<List<Relationship>> findRelationshipsForEntity(String entityId);
  Future<List<StoredMemory>> findMemoriesByEntityIds(List<String> entityIds);

  /// Lifecycle operations (used by components during consolidation).
  Future<void> updateAccessStats(List<String> ids);
  Future<int> applyImportanceDecay({
    required String component,
    required Duration inactivePeriod,
    required double decayRate,
    double? floorThreshold,
  });
  Future<void> expireSession(String sessionId, String component);
  Future<int> activeItemCount(String component, {String? sessionId});
  Future<List<StoredMemory>> activeItemsForSession(
    String sessionId,
    String component,
  );
  Future<void> expireItem(String id);

  /// Initialize storage (create tables, indexes).
  Future<void> initialize();

  /// Close storage.
  Future<void> close();
}

class ScoredMemory {
  final StoredMemory memory;
  final double bm25Score;
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

  const RecallConfig({
    this.ftsWeight = 1.0,
    this.vectorWeight = 1.5,
    this.entityWeight = 0.8,
    this.componentWeights = const {},
    this.relevanceThreshold = 0.05,
    this.topK = 20,
  });
}
```

### Score Fusion

Replace RRF with **weighted linear combination** of normalized signal scores.
This preserves magnitude:

```
finalScore = (ftsWeight × ftsScore_norm)
           + (vectorWeight × cosineSimilarity)
           + (entityWeight × entityScore_norm)
           × componentWeight
           × importanceMultiplier
           × temporalDecay
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
- `temporalDecay` = `exp(-λ × ageDays)` where λ is configurable

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
  final Budget budget;
  final RecallConfig recallConfig;
  final EmbeddingProvider? embeddings;
  final EpisodeStore episodeStore;

  /// Record, flush, consolidate — unchanged from v2.
  Future<void> record(Episode episode);
  Future<void> flush();
  Future<List<ConsolidationReport>> consolidate(LlmCallback llm);

  /// Unified recall — engine-owned, not component-delegated.
  Future<RecallResult> recall(String query) async {
    // 1. FTS5 search across all active memories.
    final ftsResults = await store.searchFts(query, limit: 50);

    // 2. Vector search (if embeddings available).
    List<_VectorMatch> vectorResults = [];
    if (embeddings != null) {
      final queryVec = await embeddings!.embed(query);
      final candidates = await store.loadActiveWithEmbeddings();
      vectorResults = _vectorSearch(queryVec, candidates);
    }

    // 3. Entity graph expansion.
    final entityResults = await _entityGraphExpansion(query);

    // 4. Merge candidates from all signals into unified score map.
    final scored = _fuseSignals(ftsResults, vectorResults, entityResults);

    // 5. Apply component weights, importance, temporal decay.
    _applyAdjustments(scored);

    // 6. Filter by relevance threshold.
    scored.removeWhere((_, v) => v.score < recallConfig.relevanceThreshold);

    // 7. Sort descending, deduplicate, take topK.
    final ranked = _rankAndDeduplicate(scored);

    // 8. Budget-aware cutoff.
    final selected = _budgetTrim(ranked, budget);

    // 9. Update access stats.
    await store.updateAccessStats(selected.map((s) => s.id).toList());

    return RecallResult(items: selected);
  }
}
```

### RecallResult

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

  /// Breakdown for observability.
  final double ftsSignal;
  final double vectorSignal;
  final double entitySignal;
}
```

The score breakdown enables the dashboard to show _why_ each memory was
recalled, which is critical for tuning.

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
  final unembedded = await store.findUnembeddedMemories(limit: 100);
  for (final mem in unembedded) {
    try {
      final vector = await embeddings!.embed(mem.content);
      await store.update(mem.id, embedding: vector);
    } catch (_) {
      // Non-fatal — memory is still searchable via FTS5.
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

## Implementation Plan

### Phase 1: Unified MemoryStore

- `StoredMemory` model with all fields
- `MemoryStore` interface
- `InMemoryMemoryStore` implementation (for tests)
- `SqliteMemoryStore` implementation (single table + FTS5 + entity tables)
- Tests for both implementations

### Phase 2: Unified Recall

- `RecallConfig` model
- Score fusion algorithm (weighted linear combination)
- Vector search integration
- Entity graph expansion (moved from DurableMemory)
- Relevance threshold filtering
- Budget trimming
- `RecallResult` / `ScoredRecall` models
- Tests with known memories and queries

### Phase 3: Component Adaptation

- Revise `MemoryComponent` interface (remove `recall()`, remove
  `ComponentBudget` from `consolidate()`)
- Adapt `TaskMemory` to write to shared store
- Adapt `EnvironmentalMemory` to write to shared store
- Adapt `DurableMemory` to write to shared store (entity graph moves to engine)
- Move embedding generation to engine post-consolidation
- Tests for each adapted component

### Phase 4: Engine Integration

- Revise `Souvenir` engine: `recall()` uses unified pipeline, `consolidate()`
  delegates to components then generates embeddings
- Remove `Mixer` (replaced by `RecallConfig` + score fusion)
- Simplify `Budget` (remove per-component allocation)
- `SouvenirCellar` factory: single collection + entity tables
- Full integration tests
- Experiment dashboard adaptation

### Phase 5: Verification

- Re-run Memory Lab experiment protocol from `experiment-log.md`
- Verify "favourite animal" → rabbits recall
- Record results in experiment log
- Tune weights based on results

---

## Open Questions

### Entity Graph Ownership

In v2, only DurableMemory writes to the entity graph. In v3, should task and
environmental components also extract entities? This could improve recall
(entity mentions in task context link to durable facts), but adds LLM cost to
task extraction. Initial plan: keep entity extraction in DurableMemory only,
but store the graph in the shared store so recall can use it for all memories.

### Importance Assignment Across Components

Components currently assign importance independently. With unified recall, a
task item at importance 0.80 competes directly with a durable item at
importance 0.40. Should importance scales be calibrated across components?
Initial plan: let component weights handle this — a durable memory at 0.40
with `componentWeight: 1.5` effectively becomes 0.60.

### Embedding All Memories

Generating embeddings for every task item adds latency and Ollama load. With
50 task items per session and 50ms per embedding, that's 2.5s per consolidation.
Initial plan: embed all (it's local and fast enough). Monitor latency and add
selective embedding if needed.

### Session-Scoped Recall Filtering

Should recall filter out expired task memories? In v2, TaskMemory's `recall()`
naturally excluded expired items. In v3, the engine needs to respect the
`status` and `invalidAt` fields during recall. Plan: the unified
`searchFts()` and `loadActiveWithEmbeddings()` both filter to
`status = 'active' AND (invalid_at IS NULL OR invalid_at > now)`.

---

## Relationship to v2 Codebase

This is a **new implementation**, not a refactor of v2:

- New branch from current main
- New `MemoryStore` replaces per-component stores
- Components rewritten to use shared store
- Engine recall logic replaces Mixer + per-component recall
- v2 code preserved on main for reference
- In-memory stores from v2 remain useful for component unit tests that don't
  need the full unified store

### Files to Create

```
lib/src/
  memory_store.dart          ← MemoryStore interface + StoredMemory
  sqlite_memory_store.dart   ← SQLite/FTS5 implementation
  in_memory_memory_store.dart ← In-memory implementation
  recall.dart                ← UnifiedRecall, RecallConfig, score fusion
  recall_result.dart         ← RecallResult, ScoredRecall
```

### Files to Modify

```
lib/src/
  engine.dart               ← recall() uses unified pipeline
  memory_component.dart     ← remove recall(), remove ComponentBudget from consolidate()
  budget.dart               ← simplify (remove per-component allocation)
  task/task_memory.dart      ← write to shared store
  environmental/environmental_memory.dart ← write to shared store
  durable/durable_memory.dart ← write to shared store, entity graph to shared store
```

### Files to Remove

```
lib/src/
  mixer.dart                ← replaced by RecallConfig
  labeled_recall.dart       ← replaced by ScoredRecall
  durable/durable_memory_store.dart ← merged into unified MemoryStore
  task/task_memory_store.dart       ← merged into unified MemoryStore
  task/cellar_task_memory_store.dart
  environmental/environmental_memory_store.dart
  environmental/cellar_environmental_memory_store.dart
  souvenir_cellar.dart      ← rewritten for unified store
```
