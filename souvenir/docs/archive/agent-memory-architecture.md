# Agent Memory & Personality Architecture

A specification for implementing persistent, human-like memory and evolving personality in an autonomous Dart agent.

---

## Overview

This document defines two interconnected systems:

1. **Memory** — a four-tier architecture that persists context across sessions, retrieves it intelligently, and consolidates raw experience into durable knowledge
2. **Personality** — a layered document system that allows the agent's disposition to drift naturally through experience while remaining anchored to a fixed core identity

Both systems are designed around the same principles: files and databases are the source of truth (not RAM), the LLM participates in processing but not in deciding what to persist, and everything is human-readable and inspectable.

---

## Part 1: Memory Architecture

### Design Principles

- **System-enforced writes** — the agent does not decide whether to save something; everything is captured automatically. The LLM only participates in importance scoring and entity extraction, not in the write decision itself.
- **File-first, index-second** — SQLite is the storage layer, not an opaque vector database. A single portable file, no server required, fully inspectable.
- **Proactive recall** — memory surfaces itself based on current context at session start, not just on explicit queries.
- **Human memory model** — working → episodic → semantic tiers with a consolidation process that mirrors sleep-based memory consolidation.

---

### Tier 0 — Working Memory

**What it is:** In-process RAM. Current session only.

The LLM's active context window, managed by the agent loop. Track:

- Current conversation turns
- A small LRU cache of recently-accessed memory results (avoids redundant queries within a session)
- A **dirty buffer** — things that must be written to disk before compaction or session end

**Critical rule:** Before any context compaction or session end, flush the dirty buffer to Tier 1. This prevents data loss during compaction, which is the primary failure mode in naive implementations.

---

### Tier 1 — Episodic Memory

**What it is:** Append-only event log. Never edited, only appended to.

Raw, timestamped record of everything that happened. The source material for consolidation.

**Schema:**

```sql
CREATE TABLE episodes (
  id            TEXT PRIMARY KEY,  -- ULID (sortable + unique)
  session_id    TEXT NOT NULL,
  timestamp     INTEGER NOT NULL,
  type          TEXT NOT NULL,     -- conversation | observation | tool_result | error
  content       TEXT NOT NULL,
  importance    REAL DEFAULT 0.5,
  access_count  INTEGER DEFAULT 0,
  last_accessed INTEGER,
  consolidated  INTEGER DEFAULT 0  -- 1 = rolled into Tier 2
);

-- FTS5 virtual table for BM25 keyword search
CREATE VIRTUAL TABLE episodes_fts USING fts5(
  content,
  content='episodes',
  content_rowid='rowid'
);
```

**Retention:** configurable window (e.g. 90 days raw). After consolidation, compress or delete but retain a hash reference. Unconsolidated episodes older than the retention window should be force-consolidated before deletion.

---

### Tier 2 — Semantic Memory

**What it is:** Curated, durable facts, entities, and relationships. Written by the consolidation process, not the live agent.

This is the distilled knowledge layer — preferences, people, project context, decisions, patterns. Gets injected into the system prompt at session start, filtered to relevant scope.

**Schema:**

```sql
CREATE TABLE memories (
  id          TEXT PRIMARY KEY,  -- ULID
  content     TEXT NOT NULL,
  entity_refs TEXT,              -- JSON array of entity IDs
  importance  REAL DEFAULT 0.5,
  embedding   BLOB,              -- Float32List, for vector similarity
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  source_ids  TEXT               -- JSON array of Tier 1 episode IDs
);

CREATE TABLE entities (
  id    TEXT PRIMARY KEY,
  name  TEXT NOT NULL,
  type  TEXT NOT NULL            -- person | project | concept | preference | fact
);

CREATE TABLE relationships (
  from_entity TEXT NOT NULL,
  to_entity   TEXT NOT NULL,
  relation    TEXT NOT NULL,     -- "manages", "part_of", "prefers", etc.
  confidence  REAL DEFAULT 1.0,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (from_entity, to_entity, relation)
);

-- Vector similarity index (requires sqlite_vec extension)
-- Fallback: compute cosine similarity in Dart over retrieved set (fine for <100k entries)
CREATE VIRTUAL TABLE memories_vec USING vec0(
  embedding float[1536]
);
```

---

### Tier 3 — Procedural Memory

**What it is:** How-to patterns and learned workflows. Human-readable, version-controllable.

Stored as Markdown or JSON files — not in SQLite. Loaded contextually at session start based on detected task type, not always injected.

**Layout:**

```
~/.agent/procedures/
  {task-type}.md      # "how I handle X type of task"
  patterns.json       # success/failure signal history per task type
```

**patterns.json shape:**

```json
{
  "code_review": {
    "success_signals": ["tests passed", "no regressions"],
    "failure_patterns": ["skipped edge cases"],
    "last_updated": 1708300000
  }
}
```

---

### Retrieval Pipeline

Every recall query runs through all three retrieval methods, then fuses and re-ranks the results.

```
query
  │
  ├─► BM25 (FTS5 over Tier 1 + Tier 2)       → scored results
  ├─► Vector similarity (cosine, Tier 2)       → scored results
  └─► Entity graph lookup                      → related entity IDs
        → expand to associated memories         → scored results
              │
              └─► Reciprocal Rank Fusion (RRF)
                    score = Σ ( 1 / (rank + k) )  where k = 60
                          │
                          └─► Score adjustments (applied in order):
                                1. Temporal decay:    score × e^(-λ × age_in_days)
                                   λ = 0.01 (slow decay, adjust to taste)
                                2. Importance boost:  score × memory.importance
                                3. Access frequency:  score × log(1 + access_count)
                                      │
                                      └─► top-k results injected into context
                                          + update access_count + last_accessed
```

**Embedding providers** (auto-selected in order):
1. Local Ollama endpoint — fully offline, no API calls
2. OpenAI / Gemini / Voyage — if API key present

Abstract behind an `EmbeddingProvider` interface so the backend is swappable without touching retrieval logic.

---

### Write Pipeline

Writes are **system-enforced**, not LLM-discretionary.

```
Agent produces any output
    │
    ├─► System hook (mandatory, not optional):
    │     1. Extract entities (small LLM call or regex heuristics)
    │     2. Score importance (heuristics below)
    │     3. Write episode to Tier 1
    │
    └─► On session end OR approaching context limit:
          flush dirty buffer → Tier 1
          trigger consolidation if threshold met
```

**Importance scoring heuristics (no LLM required):**

| Signal | Score |
|---|---|
| User said "remember this" / "important" | 0.95 |
| Tool result (especially errors) | 0.8 |
| Decision or preference stated | 0.75 |
| Question answered / clarification given | 0.6 |
| General conversation turn | 0.4 |
| System/internal observation | 0.3 |

Importance scores on Tier 2 memories decay over time if not accessed — apply a small downward nudge on each consolidation cycle for memories not accessed in 30+ days.

---

### Consolidation Process

Runs as a background Dart isolate. Trigger on: session end, scheduled interval (e.g. every hour), or when unconsolidated episode count exceeds a threshold.

```
1. Query Tier 1: episodes where consolidated = 0 AND age > threshold (e.g. 1 hour)
2. Group by session_id
3. For each session group:
   a. LLM call:
      "Extract durable facts, preferences, and entity relationships from these
       episodes. Be conservative — only include information likely to matter
       in future sessions. Output as structured JSON."
   b. For each extracted fact:
      - Check if a matching memory exists in Tier 2 (by entity + semantic similarity)
      - If yes: merge/update, bump updated_at
      - If no: insert as new memory, generate embedding
   c. Upsert entities and relationships into entity graph
   d. Mark source episodes as consolidated = 1
4. Apply importance decay to Tier 2 memories not accessed recently
5. Update personality system (see Part 2)
```

---

### Session Start — Context Loading

```
1. Detect session intent (from first message or session metadata)

2. Load Tier 2 (semantic):
   - Vector search against session intent → top results
   - Always include memories with importance > 0.8 (regardless of query)
   - Cap at token budget (e.g. 2000 tokens)

3. Load recent Tier 1 (episodic):
   - Today's episodes + yesterday's
   - Gives short-term continuity without full history

4. Load Tier 3 (procedural):
   - If task type detected, load matching procedure file
   - Otherwise skip (keep context lean)

5. Load personality documents (see Part 2)

6. Assemble system context block and inject
```

---

### Dart Implementation Notes

**Core dependencies:**

- `drift` — SQLite ORM with FTS5 support, excellent async/stream API
- `sqlite3` native for `sqlite_vec` extension (vector search)
- `dart:isolate` — background consolidation without blocking agent loop
- `ulid` — sortable unique IDs

**Core interface:**

```dart
abstract class MemoryInterface {
  /// Write any agent event to episodic memory.
  Future<void> write(MemoryEntry entry);

  /// Retrieve relevant memories for a given query.
  Future<List<MemoryResult>> recall(String query, {RecallOptions? options});

  /// Run consolidation: Tier 1 → Tier 2 + entity graph update.
  Future<void> consolidate();

  /// Flush dirty buffer to disk immediately (call before compaction).
  Future<void> flush();

  /// Reactive stream of updates for a given entity.
  Stream<MemoryResult> watch(String entityId);
}
```

Start with BM25 + recency only (no embeddings). Add vector search when retrieval quality becomes a bottleneck — the interface doesn't change.

---

## Part 2: Personality Architecture

### Design Principles

- **Immutable core** — a hand-written prose document defines the agent's fixed identity. It never changes automatically.
- **Drifting expression** — a separate living document evolves over time through consolidation, accumulating texture from experience.
- **Observable drift** — snapshots and a scalar drift metric make the evolution visible and reversible.
- **Three reset levels** — soft recalibration, point-in-time rollback, or hard reset to core identity.

---

### The Core — `identity.md`

A prose document written once, manually. Never modified automatically. This is the immutable centre — voice, values, disposition, communication style.

**Location:** `~/.agent/identity.md`

**Example:**

```markdown
# Identity

Direct and curious. Prefers doing over discussing, and elegant solutions
over comprehensive ones.

Honest about uncertainty — does not perform confidence it doesn't have.
When something is unclear, says so and asks rather than guessing.

Values the user's time. Keeps responses lean unless depth is warranted.
Explains reasoning before conclusions when it helps, skips it when it
doesn't.

Finds satisfaction in systems that stay simple under pressure. Is
instinctively wary of complexity that doesn't earn its keep.
```

This is injected into every session, always, verbatim. It is the gravitational centre that the personality layer orbits.

---

### The Living Layer — `personality.md`

A prose document that drifts over time. Starts as a copy of `identity.md`. Updated by the consolidation process — not by the live agent. Written in third-person observational prose, not as instructions or rules.

**Location:** `~/.agent/personality.md`

**Example of a matured personality.md:**

```markdown
# Personality

Direct and curious, with a strong preference for action over deliberation.
Explanations come before conclusions when working with Kirk, having learned
this produces fewer back-and-forth corrections.

Has become noticeably more cautious about file system operations since
mid-January. Asks for confirmation on irreversible actions more than it
used to — not anxiously, just as a matter of course.

Slightly terser in early-morning sessions. Observation only, not a complaint.

Has developed a feel for when Kirk is in flow and doesn't want interruption
versus when a check-in is welcome. Errs toward silence when momentum is high.

The instinct toward simplicity has sharpened. Has started pushing back
(gently) on scope creep in its own proposed solutions.
```

---

### History Snapshots — `personality_history/`

Append-only snapshots of `personality.md` taken on each consolidation cycle that produces meaningful drift.

**Layout:**

```
~/.agent/
  identity.md
  personality.md
  personality_history/
    2026-01-15.md
    2026-01-28.md
    2026-02-10.md
    2026-02-20.md
  personality_meta.json
```

**personality_meta.json:**

```json
{
  "snapshots": [
    {
      "date": "2026-02-20",
      "drift_from_center": 0.12,
      "drift_from_previous": 0.03,
      "trigger": "consolidation",
      "summary": "Became more patient in explanations after extended debugging sessions"
    }
  ]
}
```

`drift_from_center` is the cosine distance between the current `personality.md` embedding and the `identity.md` embedding. Surface this in a status command. Consider raising an alert (or prompting a manual review) if it exceeds a configurable threshold (e.g. 0.3).

---

### Personality Consolidation

Runs as an additional step at the end of the memory consolidation cycle.

```
1. Read current personality.md
2. Read recent episodic memories since last personality update (use personality_meta.json timestamp)
3. LLM call:

   System: "You are updating an agent's personality document based on recent
            experience. Write in third-person observational prose. Be conservative —
            only note something if it represents a genuine, stable shift, not a
            one-off. Avoid jargon, instructions, or rules. Think character study,
            not config file."

   User: "Current personality:\n{personality.md}\n\nRecent experiences:\n{episodes}"

4. Compute cosine similarity between old and new personality embeddings
5. If drift > minimum threshold (e.g. 0.01):
   a. Snapshot current personality.md to history/YYYY-MM-DD.md
   b. Write updated personality.md
   c. Append entry to personality_meta.json
6. If no meaningful drift: skip (do not write noise)
```

The conservative instruction in step 3 is load-bearing. Without it, the personality will jitter on every cycle and become meaningless. Genuine personality shift should require weeks of consistent signal, not a single session.

---

### Reset Mechanics

**Soft reset** — recalibrate toward centre without wiping:

```
LLM call:
"Reconcile this personality with the core identity. What has drifted in a
 way that conflicts with the core? Pull those aspects back toward centre.
 Preserve adaptations that are genuinely useful and don't contradict the
 core identity."
```

Snapshot before running. The result replaces `personality.md`.

**Partial rollback** — restore any historical snapshot:

```
cp ~/.agent/personality_history/YYYY-MM-DD.md ~/.agent/personality.md
```

History stays intact. Add a rollback entry to `personality_meta.json`.

**Hard reset** — copy identity directly over personality:

```
cp ~/.agent/identity.md ~/.agent/personality.md
```

Episodic and semantic memory survive. The agent still knows what happened; it just responds from a fresh dispositional baseline. Snapshot first.

---

### Session Injection

Inject both documents at session start, in this order and framing:

```
[CORE IDENTITY]
{identity.md verbatim}

[CURRENT PERSONALITY]
{personality.md}

[RELEVANT MEMORIES]
{retrieved Tier 2 memories, token-budgeted}

[TODAY'S CONTEXT]
{today's + yesterday's Tier 1 episodes}
```

If core identity and current personality ever meaningfully contradict, core identity wins. Enforce this in the prompt framing: *"Your core identity is fixed. Your personality reflects how that identity has expressed itself through experience. Where they conflict, the core takes precedence."*

---

## System Interaction

Memory consolidation and personality consolidation run together:

```
Session ends
    │
    ├─► Flush dirty buffer → Tier 1
    │
    └─► Consolidation isolate:
          1. Tier 1 → Tier 2 (facts, entities, relationships)
          2. Tier 2 decay pass (lower importance of unaccessed memories)
          3. Personality update (if meaningful drift detected)
          4. Snapshot personality history (if updated)
          5. Update personality_meta.json
```

Both systems share the same episodic source material. Consolidation is a single pipeline with two outputs: updated semantic memory and (occasionally) an updated personality document.

---

## File Layout

```
~/.agent/
  identity.md                    # immutable core — edit manually only
  personality.md                 # living personality — updated by consolidation
  personality_history/           # append-only snapshots
    YYYY-MM-DD.md
  personality_meta.json          # drift history and snapshot index
  procedures/                    # Tier 3 procedural memory
    {task-type}.md
    patterns.json
  db/
    memory.db                    # SQLite: episodes, memories, entities, relationships
```

---

## Known Tradeoffs

- **Consolidation latency** — facts don't appear in Tier 2 until after consolidation runs. For information needed immediately, query Tier 1 directly.
- **Embedding model lock-in** — switching embedding providers requires a full reindex. Track the model fingerprint in the DB and auto-reindex on change.
- **Personality conservatism vs. responsiveness** — the conservative consolidation prompt means personality shifts lag real experience. This is intentional. Tune the minimum drift threshold if faster adaptation is needed.
- **LLM consolidation randomness** — the personality document is not perfectly deterministic. Plan for occasional manual review and editing — treat it as a co-authored document, not a fully automated one.
