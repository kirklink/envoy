# Souvenir: How the Memory System Works

Souvenir is a persistent memory system for autonomous agents. It gives an
agent the ability to learn from experience, recall relevant knowledge, and
develop a personality over time. The system is designed around the idea that
memory should work the way human memory does: raw experiences are recorded
in the moment, distilled into lasting knowledge over time, and recalled
when relevant.

---

## The Three-Tier Architecture

Souvenir organizes memory into three tiers, each serving a different purpose.

### Tier 1: Episodic Memory (What Just Happened)

Every event the agent experiences is recorded as an **episode**: a timestamped,
typed entry tagged with a session ID.

*Layman's terms: This is the agent's short-term diary. Every conversation,
tool result, decision, and error is jotted down as it happens.*

Episodes come in six types, each with a default importance weight:

| Type | Default Importance | What It Captures |
|------|-------------------|------------------|
| `userDirective` | 0.95 | Direct instructions from the user |
| `error` | 0.80 | Failures and exceptions |
| `toolResult` | 0.80 | Output from tool executions |
| `decision` | 0.75 | Deliberate choices the agent made |
| `conversation` | 0.40 | Dialogue with the user |
| `observation` | 0.30 | Passive perceptions |

Episodes are buffered in memory and flushed to SQLite in batches (default:
every 50 episodes). They remain in Tier 1 indefinitely, but once they've
been processed by the consolidation pipeline, they're marked as consolidated
and are no longer candidates for future extraction.

### Tier 2: Semantic Memory (What the Agent Knows)

Raw episodes are noisy and session-specific. The consolidation pipeline
(described below) distills them into **semantic memories**: standalone,
self-contained facts that are useful across sessions.

*Layman's terms: This is long-term knowledge. Instead of remembering
"the user asked me to fix auth_handler.dart and I found 3 endpoints...",
the agent stores "The authentication module uses session-based auth with
cookie middleware."*

Each memory carries:
- A content string (the fact itself)
- An importance score (0.0 to 1.0)
- Links to the entities it mentions
- Links back to the source episodes it was extracted from
- An optional dense vector embedding for semantic search
- Access tracking (how often it's been recalled)

### Tier 3: Personality, Identity, and Procedures

The third tier covers three forms of persistent self-knowledge:

**Identity** is immutable text provided at construction, describing the
agent's core character. It never changes.

**Personality** starts as a copy of the identity and evolves over time as
the agent accumulates experience. The consolidation pipeline periodically
rewrites the personality based on recent episodes, producing a
third-person character study of the agent's evolving tendencies and
preferences.

*Layman's terms: Identity is who the agent was designed to be. Personality
is who it's becoming through experience.*

**Procedures** are task-specific instructions (e.g., "When debugging:
1. Reproduce the error, 2. Check logs...") provided by the caller at
construction. They're matched to incoming tasks by keyword and injected
into the session context when relevant.

---

## The Knowledge Graph

Alongside semantic memories, consolidation builds an **entity-relationship
graph**: a network of named things (people, projects, concepts, preferences)
connected by typed relationships.

*Layman's terms: The agent doesn't just know facts in isolation. It knows
that "Project X uses SQLite" and "JWT middleware depends on the jose
package" as a connected web of knowledge.*

- **Entities** are named nodes with types: `person`, `project`, `concept`,
  `preference`, or `fact`.
- **Relationships** are directed edges: `from → to` with a relation label
  (e.g., "uses", "implements", "affected_by") and a confidence score.

During recall, the retrieval pipeline walks this graph to find related
memories that wouldn't be found by text search alone. For example,
querying "Project" might find memories about "SQLite" by following a
"uses" relationship.

---

## The Write Pipeline

Recording an episode follows this path:

```
agent calls souvenir.record(episode)
  → episode added to in-memory buffer
  → if buffer.length >= flushThreshold (50):
      → batch INSERT into SQLite episodes table
      → FTS5 triggers update the search index
      → buffer is cleared
```

The buffer exists to avoid per-event database writes during fast-paced agent
sessions. The caller can force a flush at any time with `souvenir.flush()`,
and closing the Souvenir instance automatically flushes any remaining buffer.

---

## The Consolidation Pipeline

Consolidation is the process of turning raw episodes into lasting knowledge.
It runs on demand — the caller decides when by calling
`souvenir.consolidate(llm)` and passing an LLM callback.

*Layman's terms: Periodically, the agent sits down and reviews what happened,
extracts the important bits, and files them away as long-term memories.*

### Step by Step

**1. Gather unconsolidated episodes**

The pipeline queries for episodes that haven't been consolidated yet and are
older than `consolidationMinAge` (default: 5 minutes). This age gate prevents
consolidating in-progress work.

**2. Group by session**

Episodes are grouped by their session ID. Each session is processed
independently — one session's failure doesn't block others.

**3. LLM extraction**

For each session group, the pipeline sends the episodes to an LLM with a
structured extraction prompt. The LLM returns a JSON object containing:
- **Facts**: standalone statements with entity tags and importance scores
- **Relationships**: connections between entities with confidence scores

The LLM is instructed to be conservative — only extracting what matters for
future sessions, not every detail.

*Technical detail: The system prompt enforces a strict JSON schema. Markdown
code fences in the response are automatically stripped. If the LLM returns
malformed JSON, the session is skipped and episodes remain unconsolidated
for retry on the next run.*

**4. Memory merging**

For each extracted fact, the pipeline searches existing semantic memories
using FTS5 (full-text search). If a sufficiently similar memory already
exists (BM25 score above `mergeThreshold`, default: 0.5), the new fact is
**merged** into it: entity lists are unioned, importance takes the max of
both, and source episode IDs are combined. Otherwise, a new memory is
created.

*Layman's terms: If the agent already knows "the project uses SQLite" and
extracts the same fact again, it strengthens the existing memory rather than
creating a duplicate.*

**5. Entity and relationship upsert**

Named entities referenced by the extracted facts are created if they don't
exist. Relationships between entities are upserted using a composite key
(from, to, relation), so repeated extraction updates confidence scores
rather than creating duplicates.

**6. Mark episodes as consolidated**

Source episodes are flagged so they won't be processed again.

**7. Importance decay**

Memories that haven't been accessed in a configurable period (default: 30
days) have their importance reduced by a decay rate (default: 0.95, i.e., a
5% reduction per cycle). This gradually deprioritizes stale knowledge
without deleting it.

*Layman's terms: Memories the agent never uses slowly fade in priority, just
like human memories.*

**8. Embedding generation**

If an `EmbeddingProvider` is configured, the pipeline generates dense vector
embeddings for all new or merged memories. These enable semantic similarity
search — finding conceptually related memories even when they don't share
exact keywords.

*Technical detail: Embeddings are stored as BLOB columns (Float32List bytes)
in SQLite. The provider interface is abstract: any embedding service
(OpenAI, Ollama, Voyage, etc.) can be plugged in.*

**9. Personality update**

If the personality system is configured and enough new episodes have
accumulated since the last update (default threshold: 50 episodes), the
pipeline asks the LLM to rewrite the agent's personality text based on
recent experience.

The LLM receives the current personality and recent episodes, and is
instructed to write a third-person character study that reflects genuine,
stable shifts — not transient reactions. When an embedding provider is
available, the system also measures the **drift** between old and new
personality vectors (cosine distance) and rejects updates that are too
similar (below `minPersonalityDrift`, default: 0.1).

*Layman's terms: The agent's character evolves slowly and deliberately, not
after every conversation. It takes sustained, diverse experience before the
personality changes.*

### Consolidation Results

Every consolidation run returns counters:

| Counter | Meaning |
|---------|---------|
| `sessionsProcessed` | Session groups successfully extracted |
| `sessionsSkipped` | Sessions where LLM or parsing failed |
| `memoriesCreated` | New facts added to semantic memory |
| `memoriesMerged` | Facts merged into existing memories |
| `entitiesUpserted` | Entities created or updated |
| `relationshipsUpserted` | Relationships created or updated |
| `memoriesDecayed` | Memories whose importance was reduced |
| `memoriesEmbedded` | Embeddings generated |
| `personalityUpdated` | Whether personality text changed |

---

## The Retrieval Pipeline

When the agent needs to recall something — either for a direct query or to
assemble context for a new session — the retrieval pipeline runs a
multi-signal search with score fusion.

*Layman's terms: The agent doesn't just do a keyword search. It searches
multiple ways simultaneously — by keywords, by meaning, and by related
concepts — then combines the results into a single ranked list.*

### The Four Signals

**1. BM25 over episodes (episodic search)**

Full-text search using SQLite's FTS5 engine with Porter stemming. Finds
episodes whose content matches the query terms. Porter stemming means
"compile" matches "compiled", "compiling", etc.

*Technical detail: FTS5 external content mode keeps indexes separate from
data. Triggers maintain sync on INSERT/UPDATE. Queries are sanitized by
wrapping tokens in double quotes to prevent syntax errors from special
characters.*

**2. BM25 over memories (semantic search)**

Same FTS5 search, but over consolidated semantic memories instead of raw
episodes. This finds distilled facts rather than raw events.

**3. Vector similarity (when embeddings available)**

The query is embedded using the same provider that embedded the memories.
Cosine similarity is computed against every memory with an embedding.
The top candidates (default: 20) are fed into the fusion step.

*Layman's terms: Even if the agent stored a memory about "dark mode" and
you search for "theme settings", vector similarity can find the connection
because the concepts are mathematically close in meaning.*

**4. Entity graph expansion**

Entity names in the query are matched against the knowledge graph. For each
matched entity, the system follows relationships one hop to connected
entities, then finds all memories tagged with any entity in the expanded set.

*Layman's terms: Searching for "SQLite" might also surface memories about
"database optimization" because the knowledge graph knows they're connected.*

### Reciprocal Rank Fusion (RRF)

Each signal produces a ranked list of candidates. RRF combines them into a
single score:

```
fused_score = sum( 1 / (rank + K) )  for each list the item appears in
```

The constant K (default: 60) controls how much the top positions dominate.
Items that appear in multiple signals naturally score higher than items found
by only one signal.

*Layman's terms: If a memory shows up in keyword search AND meaning search
AND the knowledge graph, it gets a much higher score than something found by
only one method.*

### Score Adjustments

After fusion, three adjustments are applied:

1. **Temporal decay**: Older results are penalized exponentially.
   `score *= e^(-lambda * age_in_days)` where lambda defaults to 0.01.

2. **Importance boost**: Results are multiplied by their stored importance
   weight (0.0 to 1.0).

3. **Access frequency**: Frequently recalled items get a logarithmic boost.
   `score *= (1 + log(1 + access_count))`

### Final Filtering

- Exact content duplicates are removed (first occurrence kept)
- Optional minimum importance filter
- Top-K selection (default: 10)
- Token budget enforcement (chars / 4 heuristic)
- Access statistics are updated for returned results

---

## Session Context Assembly

When an agent starts a new task, it calls `souvenir.loadContext(sessionIntent)`
to assemble everything it needs to know. The result is a `SessionContext`
containing:

| Field | Source | Description |
|-------|--------|-------------|
| `memories` | Retrieval pipeline | Token-budgeted relevant semantic memories |
| `episodes` | Recent query | Raw episodes from the last 2 days |
| `personality` | Personality system | Current personality text |
| `identity` | Constructor | Immutable core identity |
| `procedures` | Procedure matching | Task-specific how-to docs |
| `estimatedTokens` | Calculation | Approximate token count (chars / 4) |

Procedure matching works by auto-generating keywords from task type names
(e.g., "code_review" generates ["code_review", "code review", "code",
"review"]) and checking if any appear in the session intent string. Matched
procedures are injected up to a configurable token budget (default: 2000
tokens).

---

## Pattern Tracking

The procedural memory system also tracks task outcomes:

```dart
await souvenir.recordOutcome(
  taskType: 'debugging',
  success: true,
  sessionId: 'ses_01',
  notes: 'Root cause was a race condition',
);
```

This builds a historical record of success and failure rates per task type,
stored in a `patterns` table. The track record can be summarized and
included alongside procedures to give the agent self-awareness about its
strengths and weaknesses.

---

## Tech Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Language | Dart 3.0+ | Everything |
| Database | SQLite (via `stanza_sqlite`) | All persistent state |
| ORM | Stanza | Type-safe table access and code generation |
| Full-text search | FTS5 (Porter stemming, Unicode 6.1) | Keyword search over episodes and memories |
| Vector search | Cosine similarity (in-process) | Semantic similarity on embeddings |
| Embeddings | Pluggable `EmbeddingProvider` | Dense vector generation (any provider) |
| LLM integration | `LlmCallback` typedef | Thin `(system, user) -> text` interface |
| IDs | ULID | Sortable, unique, collision-resistant |
| Code gen | `build_runner` + `stanza_builder` | ORM entity generation |

### Why SQLite?

Souvenir stores everything — episodes, memories, entities, relationships,
personality, patterns — in a single SQLite database file. This makes the
system self-contained and portable: one `.db` file is the agent's complete
memory. SQLite's FTS5 extension provides production-grade full-text search
without an external service.

For in-memory use (testing, ephemeral agents), pass `null` as the database
path and everything runs in RAM.

### Why FTS5 with Porter Stemming?

FTS5 is SQLite's full-text search engine. Porter stemming normalizes words
to their root form, so a search for "debugging" also matches "debugged" and
"debug". Unicode 6.1 tokenization handles international text.

FTS5 runs in **external content mode**: the search index doesn't duplicate
the source data. Instead, database triggers keep the index synchronized with
the source tables. This saves storage while maintaining fast search.

*Layman's terms: The search engine doesn't copy the data — it just builds an
index that points back to the original records, like the index at the back
of a textbook.*

### Why Reciprocal Rank Fusion?

Different search signals have different strengths:
- Keyword search is precise but misses synonyms
- Vector search finds semantic similarity but can be noisy
- The knowledge graph captures structural relationships

RRF combines them without requiring calibration between signals. A memory
that ranks #1 in keyword search and #3 in vector search gets a higher
combined score than something that ranks #1 in only one signal. The
math is simple (sum of reciprocal ranks) and works well in practice.

---

## Configuration

All behavior is tunable through `SouvenirConfig`:

```dart
const config = SouvenirConfig(
  // Write pipeline
  flushThreshold: 50,               // Episodes before auto-flush

  // Consolidation
  consolidationMinAge: Duration(minutes: 5),  // Min episode age
  mergeThreshold: 0.5,              // BM25 score to trigger merge

  // Importance decay
  importanceDecayRate: 0.95,        // 5% decay per cycle
  decayInactivePeriod: Duration(days: 30),    // Inactivity window

  // Retrieval
  recallTopK: 10,                   // Default result count
  rrfK: 60,                         // RRF fusion constant
  temporalDecayLambda: 0.01,        // Age penalty
  contextTokenBudget: 4000,         // Max tokens in loadContext

  // Embeddings
  embeddingTopK: 20,                // Vector search candidates

  // Personality
  minPersonalityDrift: 0.1,         // Cosine distance threshold
  personalityMinEpisodes: 50,       // Min episodes before update

  // Procedures
  maxProcedureTokens: 2000,         // Token budget for procedures
);
```

---

## Error Handling Philosophy

Souvenir is designed to be resilient rather than strict:

- **Consolidation failures are session-scoped**: If the LLM returns bad JSON
  for one session, that session is skipped but others are processed. The
  skipped episodes remain unconsolidated for retry.

- **Embedding failures are non-fatal**: If the embedding provider fails, the
  memory still exists — it just won't appear in vector search.

- **Personality update failures are non-fatal**: If the LLM call fails or
  the drift is too small, the personality simply stays as it was.

- **Retrieval is graceful**: If any signal fails, the others still contribute
  to the results. An empty result is returned rather than an exception.

The system prefers continuing with partial results over failing completely.

---

## Current Status

All six phases of the design spec are implemented and tested:

| Phase | Feature | Tests |
|-------|---------|-------|
| 1 | Episodic store + FTS5 search | Complete |
| 2 | Semantic memory + LLM consolidation | Complete |
| 3 | Multi-signal retrieval pipeline (RRF) | Complete |
| 4 | Vector embeddings + cosine similarity | Complete |
| 5 | Personality system (identity + drift) | Complete |
| 6 | Procedural memory + pattern tracking | Complete |

88 unit tests, all passing. Validated end-to-end with real Claude API calls.

Next step: integration with the Envoy agent loop, where Souvenir replaces
the current `AgentMemory` interface to provide the agent with persistent,
evolving memory across sessions.
