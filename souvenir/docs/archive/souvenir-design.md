# Souvenir — Design Specification

A persistent, human-modeled memory system for autonomous agents. Lives at
`envoy/envoy/lib/src/souvenir/` now; extracts to its own package if it earns it.

Internal terminology is "memory" throughout. The name `souvenir` is the package
identity only.

---

## 1. Public API

The consumer-facing surface. An agent (or anything else) interacts with souvenir
through a single entry point.

```dart
import 'package:envoy/souvenir.dart';

final souvenir = Souvenir(
  dbPath: '~/.agent/db/memory.db',
  llm: (system, user) => anthropicComplete(system, user),  // thin callback
  embeddings: OllamaEmbeddingProvider(),                    // optional
  identityPath: '~/.agent/identity.md',                     // optional
);

await souvenir.initialize();

// --- Write ---
await souvenir.record(Episode(
  sessionId: 'ses_01',
  type: EpisodeType.toolResult,
  content: 'File analysis completed successfully',
));

// --- Read ---
final results = await souvenir.recall('file analysis', options: RecallOptions(topK: 5));
for (final r in results) {
  print('[${r.score}] ${r.content}');
}

// --- Session start ---
final context = await souvenir.loadContext('Help me refactor the auth module');
// context.memories     → relevant Tier 2 memories
// context.episodes     → recent Tier 1 episodes
// context.personality  → current personality text
// context.identity     → core identity text
// context.procedures   → matching procedural docs

// --- Background ---
await souvenir.consolidate();  // episodic → semantic + personality update
await souvenir.flush();        // force working memory to disk
```

### Core API Surface

```dart
class Souvenir {
  Souvenir({
    required String dbPath,
    required LlmCallback llm,
    EmbeddingProvider? embeddings,
    String? identityPath,
    SouvenirConfig config = const SouvenirConfig(),
  });

  Future<void> initialize();
  Future<void> close();

  // Tier 1 — write
  Future<void> record(Episode episode);
  Future<void> flush();

  // Read — unified retrieval across all tiers
  Future<List<Recall>> recall(String query, {RecallOptions? options});

  // Session context assembly
  Future<SessionContext> loadContext(String sessionIntent);

  // Consolidation — episodic → semantic + personality
  Future<void> consolidate();

  // Personality access
  String get identity;
  String get personality;
}
```

### Thin LLM Interface

```dart
/// Prompt in, text out. The memory system doesn't care about the provider.
typedef LlmCallback = Future<String> Function(String system, String user);
```

### Embedding Interface

```dart
/// Abstract provider for text embeddings. Start with no-op; plug in real
/// providers (Ollama, OpenAI, Voyage) when ready.
abstract class EmbeddingProvider {
  Future<List<double>> embed(String text);
  int get dimensions;
}
```

---

## 2. Data Models

### Episode (Tier 1 — Episodic)

Raw, timestamped event. Append-only. Source material for consolidation.

```dart
class Episode {
  final String id;            // ULID (auto-generated if not provided)
  final String sessionId;
  final DateTime timestamp;   // defaults to now
  final EpisodeType type;
  final String content;
  final double importance;    // 0.0–1.0, heuristic-scored
  final int accessCount;
  final DateTime? lastAccessed;
  final bool consolidated;
}

enum EpisodeType {
  conversation,   // 0.4 default importance
  observation,    // 0.3
  toolResult,     // 0.8
  error,          // 0.8
  decision,       // 0.75
  userDirective,  // 0.95 ("remember this")
}
```

### Memory (Tier 2 — Semantic)

Curated, durable fact distilled from episodes. Written by consolidation, not
the live agent.

```dart
class Memory {
  final String id;            // ULID
  final String content;
  final List<String> entityIds;
  final double importance;    // 0.0–1.0
  final List<double>? embedding;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> sourceEpisodeIds;
  final int accessCount;
  final DateTime? lastAccessed;
}
```

### Entity & Relationship

Named entities and their connections. The knowledge graph skeleton.

```dart
class Entity {
  final String id;            // ULID
  final String name;
  final EntityType type;
}

enum EntityType { person, project, concept, preference, fact }

class Relationship {
  final String fromEntityId;
  final String toEntityId;
  final String relation;      // "manages", "part_of", "prefers", etc.
  final double confidence;    // 0.0–1.0
  final DateTime updatedAt;
}
```

### Recall (retrieval result)

```dart
class Recall {
  final String id;
  final String content;
  final double score;         // fused score after RRF + adjustments
  final RecallSource source;  // episodic | semantic | entity
  final DateTime timestamp;
  final double importance;
}

enum RecallSource { episodic, semantic, entity }
```

### SessionContext (assembled at session start)

```dart
class SessionContext {
  final List<Memory> memories;     // relevant Tier 2, token-budgeted
  final List<Episode> episodes;    // recent Tier 1 (today + yesterday)
  final String? personality;       // current personality.md content
  final String? identity;          // core identity.md content
  final List<String> procedures;   // matching Tier 3 docs
}
```

### Configuration

```dart
class SouvenirConfig {
  final int episodeRetentionDays;       // default: 90
  final int consolidationThreshold;     // episodes before auto-consolidate
  final Duration consolidationMinAge;   // min episode age before consolidation
  final int contextTokenBudget;         // max tokens for session context
  final double importanceDecayRate;     // per-consolidation decay for unaccessed
  final double temporalDecayLambda;     // e^(-λ × age_days), default 0.01
  final double minPersonalityDrift;     // cosine distance threshold
  final int recallTopK;                 // default top-k for recall
}
```

---

## 3. Storage Schema (SQLite)

### Regular Tables (via Stanza entities + code gen)

```sql
-- Tier 1: Episodic memory
CREATE TABLE episodes (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL,
  timestamp     INTEGER NOT NULL,    -- unix millis
  type          TEXT NOT NULL,
  content       TEXT NOT NULL,
  importance    REAL NOT NULL DEFAULT 0.5,
  access_count  INTEGER NOT NULL DEFAULT 0,
  last_accessed INTEGER,
  consolidated  INTEGER NOT NULL DEFAULT 0
);

-- Tier 2: Semantic memory
CREATE TABLE memories (
  id          TEXT PRIMARY KEY,
  content     TEXT NOT NULL,
  entity_ids  TEXT,                   -- JSON array
  importance  REAL NOT NULL DEFAULT 0.5,
  embedding   BLOB,                   -- Float32List bytes
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  source_ids  TEXT,                   -- JSON array of episode IDs
  access_count  INTEGER NOT NULL DEFAULT 0,
  last_accessed INTEGER
);

-- Entity graph
CREATE TABLE entities (
  id    TEXT PRIMARY KEY,
  name  TEXT NOT NULL,
  type  TEXT NOT NULL
);

CREATE TABLE relationships (
  from_entity TEXT NOT NULL,
  to_entity   TEXT NOT NULL,
  relation    TEXT NOT NULL,
  confidence  REAL NOT NULL DEFAULT 1.0,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (from_entity, to_entity, relation)
);
```

### FTS5 Virtual Tables (via Stanza's FTS5 API)

Stanza's `stanza_sqlite` package supports FTS5 natively. Uses **external
content mode**: FTS5 stores only the search index, not duplicate data. Points
back to the source table via `content_rowid`. Trigger-based sync keeps the
index consistent automatically.

**Configuration:**

```dart
// Episodes FTS index
const episodesFts = Fts5Index(
  sourceTable: 'episodes',
  columns: ['content'],
  contentRowid: 'rowid',          // maps to source table PK
  tokenize: 'porter unicode61',  // stemming + unicode
);

// Memories FTS index
const memoriesFts = Fts5Index(
  sourceTable: 'memories',
  columns: ['content'],
  contentRowid: 'rowid',
  tokenize: 'porter unicode61',
);
```

**DDL (generated by Stanza):**

```dart
// In initialize():
await db.rawExecute(SqliteDdl.createFts5Table(episodesFts));
for (final trigger in SqliteDdl.createFts5Triggers(episodesFts)) {
  await db.rawExecute(trigger);
}
// Same for memoriesFts
```

This creates:
- Virtual table (`episodes_fts`) with external content pointing to `episodes`
- Three triggers (INSERT/DELETE/UPDATE) to keep the index in sync
- No manual FTS maintenance needed — triggers handle it

**Queries (via Stanza's typed API):**

```dart
// BM25-ranked search over episodes
final results = await db.execute(
  SelectQuery(episodes)
    .fts5Join('episodes_fts', (t) => t.id, query)
    .selectFts5Rank('episodes_fts'),
);

// With column weights (if multiple indexed columns)
final results = await db.execute(
  SelectQuery(memories)
    .fts5Join('memories_fts', (t) => t.id, query)
    .selectFts5Rank('memories_fts', weights: [1.0]),
);
```

**Note:** FTS5's BM25 rank is negative (closer to 0 = better match). Normalize
to positive scores in the retrieval pipeline.

---

## 4. Write Pipeline

System-enforced. Every call to `record()` writes. The caller decides what to
record; souvenir decides nothing about whether to store it.

```
record(Episode)
  │
  ├─► Assign ULID if not provided
  ├─► Apply importance heuristic from EpisodeType
  ├─► Add to working memory buffer (in-process)
  │
  └─► If buffer exceeds flush threshold:
        flush() → batch INSERT into episodes table
                  (FTS5 sync via trigger, no extra work)
```

### Importance Heuristics (no LLM needed)

| EpisodeType     | Default Importance |
|-----------------|--------------------|
| userDirective   | 0.95               |
| toolResult      | 0.80               |
| error           | 0.80               |
| decision        | 0.75               |
| conversation    | 0.40               |
| observation     | 0.30               |

Callers can override importance on individual episodes.

### Flush Triggers

- Buffer size exceeds threshold (e.g. 50 episodes)
- `flush()` called explicitly
- `consolidate()` called (flushes first)
- `close()` called

---

## 5. Retrieval Pipeline

Every `recall()` query runs through all available retrieval methods, fuses
results, and applies score adjustments.

```
recall(query)
  │
  ├─► BM25 over episodes_fts      → scored results (normalized rank)
  ├─► BM25 over memories_fts      → scored results (normalized rank)
  ├─► [if embeddings] Vector similarity over memories.embedding → scored
  └─► Entity graph expansion       → entity IDs → associated memories → scored
        │
        └─► Reciprocal Rank Fusion (RRF)
              score = Σ( 1 / (rank_in_list + k) )  where k = 60
                    │
                    └─► Score adjustments (applied in order):
                          1. Temporal decay:   score × e^(-λ × age_days)
                          2. Importance boost:  score × importance
                          3. Access frequency:  score × log(1 + access_count)
                                │
                                └─► Deduplicate by content similarity
                                    │
                                    └─► top-k results
                                        + update access_count, last_accessed
```

### RecallOptions

```dart
class RecallOptions {
  final int topK;           // default: 10
  final int? tokenBudget;   // cap results by estimated tokens
  final bool includeEpisodic;  // default: true
  final bool includeSemantic;  // default: true
  final double? minImportance; // filter floor
  final String? sessionId;     // scope to specific session
}
```

### Entity Graph Lookup

```
query → extract entity names (simple matching against entities table)
      → lookup entity IDs
      → query relationships for connected entities
      → expand to associated memories (via entity_ids JSON array)
      → score by relationship confidence
```

---

## 6. Consolidation Pipeline

Distills episodic memory into semantic memory. Runs on demand via
`consolidate()`. The caller decides when (post-session, scheduled, etc.).

```
consolidate()
  │
  ├─► flush() — ensure all buffered episodes are on disk
  │
  ├─► Query episodes: consolidated = 0 AND age > consolidationMinAge
  │
  ├─► Group by session_id
  │
  ├─► For each session group:
  │     │
  │     ├─► LLM call:
  │     │     system: "Extract durable facts, preferences, and entity
  │     │              relationships. Be conservative. Output JSON."
  │     │     user:   episode contents
  │     │
  │     ├─► For each extracted fact:
  │     │     ├─► Search existing memories (BM25 + entity match)
  │     │     ├─► If match: merge, bump updated_at
  │     │     └─► If new: insert, generate embedding (if provider available)
  │     │
  │     ├─► Upsert entities and relationships
  │     │
  │     └─► Mark source episodes: consolidated = 1
  │
  ├─► Importance decay pass:
  │     memories not accessed in 30+ days → importance × 0.95
  │
  └─► [if personality enabled] Personality consolidation (see §7)
```

### Consolidation LLM Prompt

```
System: You are extracting durable knowledge from an agent's recent experience.
Output a JSON object with two arrays:

{
  "facts": [
    {
      "content": "...",
      "entities": [{"name": "...", "type": "person|project|concept|preference|fact"}],
      "importance": 0.0-1.0
    }
  ],
  "relationships": [
    {"from": "entity_name", "to": "entity_name", "relation": "..."}
  ]
}

Be conservative. Only include information likely to matter in future sessions.
Prefer updating existing knowledge over creating duplicates.
```

---

## 7. Personality System

Layered: immutable core identity + drifting personality expression.

### Identity (`identity.md`)

Written once, manually. Never modified by the system. Loaded from
`identityPath` at initialization. Injected verbatim into every session context.

### Personality (`personality.md`)

Starts as a copy of identity. Updated by consolidation. Written in third-person
observational prose. Stored adjacent to the database file (sibling path derived
from `dbPath`).

### Personality Consolidation

Runs as an additional step at the end of `consolidate()`:

```
1. Read current personality.md
2. Gather recent episodes since last personality update
3. LLM call:
     system: "Update agent personality based on recent experience.
              Third-person observational prose. Conservative — only genuine,
              stable shifts. Character study, not config file."
     user:   current personality + recent episodes
4. Compute drift (cosine distance if embeddings available, else skip)
5. If drift > minPersonalityDrift:
     a. Snapshot current → personality_history/YYYY-MM-DD.md
     b. Write updated personality.md
     c. Update personality_meta.json
```

### Reset Mechanics

```dart
// Soft reset — recalibrate toward identity
await souvenir.resetPersonality(ResetLevel.soft);

// Rollback — restore historical snapshot
await souvenir.resetPersonality(ResetLevel.rollback, date: DateTime(2026, 1, 15));

// Hard — copy identity over personality
await souvenir.resetPersonality(ResetLevel.hard);
```

---

## 8. Procedural Memory (Tier 3)

File-based, human-readable. Stored alongside the database.

```
{dbDir}/procedures/
  code_review.md
  debugging.md
  patterns.json          # success/failure signals per task type
```

Loaded contextually at session start based on detected task type. Not always
injected — keeps context lean.

---

## 9. File Layout

```
envoy/envoy/lib/
  souvenir.dart                   ← barrel export
  src/souvenir/
    souvenir.dart                 ← Souvenir class (public API)
    config.dart                   ← SouvenirConfig
    models/
      episode.dart                ← Episode, EpisodeType
      memory.dart                 ← Memory (Tier 2)
      entity.dart                 ← Entity, EntityType, Relationship
      recall.dart                 ← Recall, RecallOptions, RecallSource
      session_context.dart        ← SessionContext
    store/
      souvenir_store.dart         ← SouvenirStore (SQLite operations)
      schema.dart                 ← DDL constants, FTS5 setup
      stanza_entities.dart        ← Stanza entity definitions (code gen input)
      stanza_entities.g.dart      ← Generated table descriptors
    pipelines/
      retrieval.dart              ← RetrievalPipeline (BM25 + vector + entity → RRF)
      consolidation.dart          ← ConsolidationPipeline
      write.dart                  ← WritePipeline (buffer + flush)
    personality/
      personality.dart            ← PersonalityManager
    providers/
      llm.dart                    ← LlmCallback typedef
      embedding.dart              ← EmbeddingProvider abstract class
```

---

## 10. Dependencies

| Package          | Purpose                                    | Phase |
|------------------|--------------------------------------------|-------|
| `stanza_sqlite`  | SQLite adapter, typed CRUD, FTS5, transactions | 1 |
| `stanza_builder` | Code gen for table descriptors             | 1     |
| `ulid`           | Sortable unique IDs                        | 1     |
| `ml_linalg`      | Cosine similarity (SIMD-optimized)         | 4     |
| `path`           | File path handling                         | 1     |

Stanza handles everything including FTS5 (typed queries via `fts5Join()` +
`selectFts5Rank()`, DDL via `SqliteDdl.createFts5Table()` + triggers).
No drift dependency needed.

### Token Estimation

For `RecallOptions.tokenBudget`, start with a chars/4 heuristic (~80%
accurate for English). Dart tokenizer packages exist if we need precision:
- `tiktoken` (v1.0.3) — pure Dart BPE, OpenAI model encodings
- `dart_sentencepiece_tokenizer` (v1.3.0) — SentencePiece BPE/Unigram

Claude doesn't publish a Dart tokenizer, but BPE encodings are close enough
for budget estimation. Anthropic also offers a `/count-tokens` API endpoint
for exact counts (requires network call).

---

## 11. Phase Map

### Phase 1: Foundation — Episodic Store + FTS5

The minimum useful system: write events, search them, get them back.

- [ ] Directory structure + barrel export
- [ ] Episode model + EpisodeType enum
- [ ] SouvenirConfig
- [ ] Stanza entity for episodes table + code gen
- [ ] SouvenirStore — SQLite connection via `StanzaSqlite`, DDL
- [ ] FTS5 setup via `Fts5Index` + `SqliteDdl.createFts5Table/Triggers`
- [ ] WritePipeline — in-memory buffer + batch flush to SQLite
- [ ] BM25 recall over episodes via `fts5Join()` + `selectFts5Rank()`
- [ ] Souvenir class skeleton (initialize, record, recall, flush, close)
- [ ] Tests (first real-world consumer of Stanza's SQLite FTS5)

**Delivers:** A working episodic memory with full-text search. Useful standalone.
Also validates Stanza's new FTS5 API in a real use case.

### Phase 2: Semantic Memory + Consolidation

Raw episodes become curated knowledge.

- [ ] Memory model (Tier 2)
- [ ] Entity + Relationship models
- [ ] Stanza entities for memories, entities, relationships tables
- [ ] memories_fts virtual table + triggers
- [ ] LlmCallback typedef
- [ ] ConsolidationPipeline (episodic → semantic, entity extraction)
- [ ] consolidate() wired into Souvenir
- [ ] Importance decay pass
- [ ] Tests

**Delivers:** Episodic + semantic memory with LLM-powered distillation.

### Phase 3: Retrieval Pipeline

Multi-signal retrieval with intelligent ranking.

- [ ] RetrievalPipeline (BM25 episodic + BM25 semantic + entity graph)
- [ ] Reciprocal Rank Fusion
- [ ] Score adjustments (temporal decay, importance, access frequency)
- [ ] RecallOptions (topK, tokenBudget, filters)
- [ ] Recall model with scores and source attribution
- [ ] SessionContext assembly (loadContext)
- [ ] Upgrade recall() to use full pipeline
- [ ] Tests

**Delivers:** Intelligent memory retrieval. The system finds what matters.

### Phase 4: Embeddings

Semantic similarity via vector search.

- [ ] EmbeddingProvider interface
- [ ] Vector storage in memories table (BLOB)
- [ ] Cosine similarity computation (ml_linalg)
- [ ] Integrate vector search as third signal in RetrievalPipeline
- [ ] Generate embeddings during consolidation
- [ ] At least one concrete provider (Ollama or API-based)
- [ ] Tests

**Delivers:** Find memories by meaning, not just keywords.

### Phase 5: Personality

Stable identity with layered drift potential.

- [ ] PersonalityManager (load identity.md, load/write personality.md)
- [ ] Personality consolidation step (extends consolidation pipeline)
- [ ] History snapshots + personality_meta.json
- [ ] Drift metrics (cosine distance if embeddings available)
- [ ] Reset mechanics (soft, rollback, hard)
- [ ] Wire into SessionContext (identity + personality fields)
- [ ] Tests

**Delivers:** Agent personality that can observe its own evolution.

### Phase 6: Procedural Memory

Task-specific how-to knowledge.

- [ ] File-based procedure loading
- [ ] patterns.json (success/failure tracking)
- [ ] Task-type detection heuristics
- [ ] Wire into loadContext (conditional injection)
- [ ] Tests

**Delivers:** The agent knows how it handles specific types of work.

---

## 12. Integration with Envoy (post-souvenir)

Souvenir replaces the current `AgentMemory` interface. Integration points:

1. **Agent loop** calls `souvenir.record()` for each event (tool results,
   conversations, errors, decisions)
2. **Session start** calls `souvenir.loadContext()` and injects into system prompt
3. **Post-task** calls `souvenir.consolidate()` (replaces current `reflect()`)
4. **Agent constructor** takes `Souvenir` instead of `AgentMemory?`

The existing `AgentMemory` interface and `StanzaMemoryStorage` remain until
migration is complete, then are removed.

---

## 13. Resolved Questions

1. **FTS5 support** — Stanza's `stanza_sqlite` now has full FTS5 support:
   `Fts5Index` config, `SqliteDdl.createFts5Table()` + `createFts5Triggers()`,
   typed queries via `fts5Join()` + `selectFts5Rank()`. No raw SQL needed.
   First real-world consumer of this API — will validate it.

2. **External content mode** — Using external content FTS5 (what Stanza
   implements). FTS5 stores only the index, not duplicate data. Trigger-based
   sync keeps it consistent. Source tables (episodes, memories) are the single
   source of truth.

3. **Consolidation scheduling** — Souvenir exposes `consolidate()` but does
   not schedule it. The caller decides when. We'll revisit scheduling after
   seeing how consolidation works in practice.

4. **Token estimation** — Start with chars/4 heuristic. Dart BPE tokenizer
   packages exist (`tiktoken`, `dart_sentencepiece_tokenizer`) if precision
   becomes important. Upgrade path is clear.

## 14. Open Questions

1. **Stanza SQLite `content_rowid` mapping**: Stanza's `Fts5Index` uses
   `contentRowid` to map the FTS5 rowid to the source table's PK. Our
   episodes/memories tables use TEXT ULIDs as PKs, not INTEGER rowids.
   FTS5 external content requires an INTEGER rowid. Options:
   - Add an INTEGER `rowid` alias column to source tables
   - Use SQLite's implicit `rowid` (every table has one unless WITHOUT ROWID)
   - Needs validation with Stanza's FTS5 implementation

2. **Stanza code gen in souvenir**: Souvenir will use Stanza entities for typed
   table access. This means `build_runner` + `stanza_builder` as dev
   dependencies. The generated `.g.dart` files live alongside the entity
   definitions. Confirm this works within envoy's existing build setup.
