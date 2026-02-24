# Souvenir v2 — Composable Memory Architecture

Redesign of Souvenir's memory system from a monolithic three-tier pipeline to a
composable engine with pluggable memory components.

Supersedes the single-pipeline design in `souvenir-design.md` for the memory
storage/recall layer. Episode recording, flush, and the LLM callback interface
remain unchanged.

---

## Problem Statement

Souvenir v1 treats all consolidated knowledge the same way: a single extraction
prompt, a single importance score, a single decay curve, a single retrieval
pipeline. This creates problems observed in the Memory Lab experiment:

1. **Task context masquerades as preferences.** "User prefers exactly 5 numbers"
   is session-scoped task context, not a durable preference. But it's stored
   identically to "user prefers composition over inheritance" and recalled with
   the same weight.

2. **One decay curve fits nothing well.** Task context should decay within hours.
   Environmental context (what happened recently) should decay over days.
   Genuine preferences should persist for months or indefinitely. A single
   30-day decay rate is too slow for tasks and too fast for preferences.

3. **No way to swap strategies.** The extraction prompt, scoring formula, and
   merge logic are hardcoded in `ConsolidationPipeline` and `RetrievalPipeline`.
   Experimenting with different memory behaviors requires modifying core code.

4. **Keyword recall without intent.** "Can rabbits code in dart?" triggers recall
   of Dart programming memories because the retrieval pipeline can't distinguish
   topical relevance from keyword coincidence. Different memory types might need
   different relevance strategies.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Souvenir Engine                       │
│                                                         │
│  ┌──────────────┐    ┌──────────────────────────────┐   │
│  │ EpisodeBuffer│───→│  Consolidation Trigger        │   │
│  │  (unchanged) │    │  (schedule / threshold / API) │   │
│  └──────────────┘    └──────────┬───────────────────┘   │
│                                 │                       │
│                    episodes exposed to all components    │
│                                 │                       │
│          ┌──────────────────────┼──────────────────┐    │
│          ▼                      ▼                  ▼    │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐│
│  │ TaskMemory   │   │ Environmental│   │ DurableMemory││
│  │ (component)  │   │ Memory       │   │ (component)  ││
│  │              │   │ (component)  │   │              ││
│  └──────┬───────┘   └──────┬───────┘   └──────┬───────┘│
│         │                  │                   │        │
│         └──────────────────┼───────────────────┘        │
│                            ▼                            │
│                    ┌──────────────┐                      │
│                    │    Mixer     │                      │
│                    │  (weighing + │                      │
│                    │   ranking)   │                      │
│                    └──────┬───────┘                      │
│                           ▼                             │
│                   Mixed context for                     │
│                    system prompt                        │
└─────────────────────────────────────────────────────────┘
```

### Pipeline Flow

1. **Record** — Episodes are buffered and flushed to storage (unchanged from v1).

2. **Consolidation trigger** — On schedule, threshold, or explicit API call.
   The engine fetches unconsolidated episodes.

3. **Component consolidation** — All registered `MemoryComponent`s receive the
   episodes and an LLM callback concurrently via `Future.wait()`. Each component
   independently decides what (if anything) to extract and store. Components
   have the _opportunity_ but not the _obligation_ to consume episodes.
   Components are fully independent so there is no ordering dependency.

4. **Recall** — On each turn, the engine provides the user's query/intent to
   every component. Each component independently returns labeled recall items
   within its token budget.

5. **Mixing** — A configurable `Mixer` receives labeled recalls from all
   components, rebalances scores across components (since each component's
   scoring scale is independent), deduplicates if configured to, and produces
   the final ranked context. The mixer reports on budget usage (per-component
   and overall) but does not enforce component budgets — that's the
   component's responsibility. Budget reporting enables the engine to flag
   components that consistently exceed their allocation.

6. **Injection** — The mixed context is formatted into the system prompt.
   Each item is labeled with its source component name.

---

## Core Interfaces

### MemoryComponent

The unit of pluggability. Each component owns its own storage, extraction logic,
decay strategy, and recall behavior.

```dart
abstract class MemoryComponent {
  /// Unique name, used for budget allocation and recall labeling.
  String get name;

  /// Called once at engine startup.
  Future<void> initialize();

  /// Consolidation: episodes are available. Extract what you need.
  /// Returns a report of what was consumed/created.
  /// The [llm] callback is provided for components that need LLM extraction;
  /// purely programmatic components may ignore it.
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
    ComponentBudget budget,
  );

  /// Recall: return items relevant to the query, within your budget.
  Future<List<LabeledRecall>> recall(
    String query,
    ComponentBudget budget,
  );

  /// Cleanup.
  Future<void> close();
}
```

### ConsolidationReport

Each component reports what it did during consolidation so the engine can log,
display in the dashboard, and inform future tuning.

```dart
class ConsolidationReport {
  final String componentName;
  final int itemsCreated;
  final int itemsMerged;
  final int itemsDecayed;
  final int episodesConsumed;
}
```

### LabeledRecall

Recall items carry their source component name so the mixer and the final
system prompt can attribute them.

```dart
class LabeledRecall {
  final String componentName;
  final String content;

  /// Component-local relevance score. Each component defines its own scoring
  /// scale — scores are NOT comparable across components. The mixer's job is
  /// to rebalance these into a unified ranking using its per-component
  /// weighting algorithm.
  final double score;

  final Map<String, dynamic>? metadata;
}
```

**Note on scoring**: A score of 0.9 from `TaskMemory` means something different
than 0.9 from `DurableMemory` — the scales are independent. The mixer
configuration is therefore more of an algorithm than a simple set of weights: it
must normalize, rebalance, and rank across heterogeneous scoring scales. The
`WeightedMixer` handles this with per-component weight multipliers as a starting
point, but more sophisticated mixers could use distribution normalization or
learned calibration.

### Tokenizer

A shared token-counting utility provided by the engine. All components MUST use
the engine's tokenizer rather than implementing their own, ensuring consistent
budget accounting across the system.

```dart
abstract class Tokenizer {
  /// Count tokens in a string.
  int count(String text);
}

/// Proper tokenizer using a model-appropriate algorithm (e.g. tiktoken or
/// similar). Preferred implementation.
class ModelTokenizer implements Tokenizer { ... }

/// Fallback: character count / 4. Acceptable approximation when a proper
/// tokenizer is unavailable or too expensive to run.
class ApproximateTokenizer implements Tokenizer {
  @override
  int count(String text) => (text.length / 4).ceil();
}
```

The engine owns the `Tokenizer` instance and passes it through
`ComponentBudget` so components never need to import or construct their own.

### Budget

Manages token allocation across components. The engine owns the total budget;
each component receives a view of its allocation and reports usage.

```dart
class Budget {
  final int totalTokens;
  final Map<String, int> allocation;  // componentName → token limit
  final Tokenizer tokenizer;

  /// Returns this component's allocation with a reference to the shared
  /// tokenizer.
  ComponentBudget forComponent(String name);
}

class ComponentBudget {
  final int allocatedTokens;
  final Tokenizer tokenizer;
  int usedTokens = 0;

  int get remainingTokens => allocatedTokens - usedTokens;

  /// Count tokens in [text] using the shared tokenizer and record consumption.
  int consume(String text) {
    final tokens = tokenizer.count(text);
    usedTokens += tokens;
    return tokens;
  }
}
```

### Mixer

Takes labeled recalls from all components and produces the final ranked list
for the system prompt. The mixer does not enforce component budgets (that's each
component's responsibility) but reports on budget usage so the engine can flag
components that consistently exceed their allocation.

The default implementation uses configurable per-component weights to rebalance
scores across heterogeneous component scales. The interface allows swapping in
more sophisticated strategies.

```dart
class MixResult {
  final List<LabeledRecall> items;
  final Map<String, BudgetUsage> componentUsage;  // per-component report
  final int totalTokensUsed;
}

class BudgetUsage {
  final String componentName;
  final int allocated;
  final int used;
  bool get overBudget => used > allocated;
}

abstract class Mixer {
  MixResult mix(
    Map<String, List<LabeledRecall>> componentRecalls,
    Budget budget,
  );
}

/// Default: weighted rebalance with configurable per-component weights.
class WeightedMixer implements Mixer {
  final Map<String, double> weights;  // componentName → weight multiplier

  @override
  MixResult mix(
    Map<String, List<LabeledRecall>> componentRecalls,
    Budget budget,
  ) {
    // 1. Multiply each item's score by its component weight to normalize
    //    across heterogeneous scoring scales.
    // 2. Merge all items into a single list.
    // 3. Sort by adjusted score descending.
    // 4. Take items until total token budget is exhausted.
    // 5. Report per-component budget usage.
    // 6. Return MixResult with items and usage report.
  }
}
```

---

## Engine Composition

The Souvenir engine is a registry and coordinator — it owns the episode buffer,
the component list, the budget, and the mixer. It does not contain memory logic
itself.

```dart
class Souvenir {
  final List<MemoryComponent> components;
  final Budget budget;
  final Mixer mixer;
  final EpisodeBuffer _buffer;

  /// Record an episode (unchanged from v1).
  Future<void> record(Episode episode);
  Future<void> flush();

  /// Consolidation: expose episodes to all components concurrently.
  /// Components are independent — no ordering dependency.
  Future<List<ConsolidationReport>> consolidate(LlmCallback llm) async {
    final episodes = await _fetchUnconsolidated();
    final reports = await Future.wait(
      components.map((c) => c.consolidate(
        episodes,
        llm,
        budget.forComponent(c.name),
      )),
    );
    await _markConsolidated(episodes);
    return reports;
  }

  /// Recall: query all components concurrently, mix results.
  Future<MixResult> recall(String query) async {
    final results = await Future.wait(
      components.map((c) async =>
        MapEntry(c.name, await c.recall(query, budget.forComponent(c.name))),
      ),
    );
    final componentRecalls = Map.fromEntries(results);
    return mixer.mix(componentRecalls, budget);
  }

  /// Assemble full session context.
  Future<SessionContext> loadContext(String intent);

  /// Lifecycle: close all components.
  Future<void> close() async {
    await Future.wait(components.map((c) => c.close()));
  }
}
```

---

## Example Components

These are illustrative — the architecture does not prescribe which components
exist. Any combination can be registered.

### TaskMemory ✅

Tracks what we are currently doing within a work session.

- **Extraction**: Aggressively captures decisions, tool results, and current
  objectives from episodes. Uses an LLM prompt focused on "what is the user
  trying to accomplish RIGHT NOW?" Items categorized: goal, decision, result,
  context. LLM returns `action: new|merge` — merge finds similar items via
  store's `findSimilar()` and updates in place.
- **Decay**: Fast — session boundary detection expires all items from previous
  sessions. `maxItemsPerSession` cap evicts lowest-importance items.
- **Recall**: Scores items by keyword overlap × category weight × recency decay.
  Goals rank higher than context. Floor score ensures current-session items
  always surface. Updates access stats.
- **Storage**: `InMemoryTaskMemoryStore` (unit tests) or `CellarTaskMemoryStore`
  (production — FTS5 search, Cellar CRUD). Both implement `TaskMemoryStore`.
- **Config**: `TaskMemoryConfig` — `maxItemsPerSession`, `defaultImportance`,
  `mergeThreshold`, `recencyDecayLambda`, `recallTopK`, `categoryWeights`.

### EnvironmentalMemory ✅

What has happened recently — self-awareness and situational context.

- **Extraction**: Captures capabilities, constraints, environment details, and
  behavioral patterns. LLM prompt focused on "reflecting on what you've learned
  about yourself and your environment." Items categorized: capability,
  constraint, environment, pattern. Merge via `findSimilar()`.
- **Decay**: Medium — `importanceDecayRate` (default 0.95) applied to items not
  updated within `inactivePeriod` (default 14 days). Items falling below
  `decayFloorThreshold` (default 0.1) are marked `decayed`. No session boundary
  expiration — environmental knowledge persists across sessions.
- **Recall**: Scores items by keyword overlap × category weight × recency decay.
  Capabilities rank higher than patterns. Budget-aware cutoff. Updates access
  stats.
- **Storage**: `InMemoryEnvironmentalMemoryStore` (unit tests) or
  `CellarEnvironmentalMemoryStore` (production — FTS5 search, raw SQL decay).
  Both implement `EnvironmentalMemoryStore`.
- **Config**: `EnvironmentalMemoryConfig` — `maxItems`, `defaultImportance`,
  `mergeThreshold`, `recencyDecayLambda`, `recallTopK`, `importanceDecayRate`,
  `decayFloorThreshold`, `inactivePeriod`, `categoryWeights`.

### DurableMemory ✅

Genuine preferences, learned facts, and long-term knowledge.

- **Extraction**: Very selective. LLM prompt specifically asks: "Is this a
  durable fact that would matter months from now, independent of any specific
  task?" High bar for inclusion. Conflict resolution: duplicate detection via
  BM25, contradiction handling via LLM-generated `conflict` field, supersession
  chain tracking.
- **Decay**: Very slow — months. Access resets decay timer. Importance threshold
  for inclusion is high. `applyImportanceDecay()` runs during consolidation.
- **Recall**: Always considered. Weighted highly by the mixer. BM25 FTS5 search
  + entity graph expansion (entities → relationships → related memories).
  Deduplicates by content. Updates access stats on recalled items.
- **Storage**: `DurableMemoryStore` — raw `sqlite3.Database` (accessed via
  `cellar.database`). 4 tables: memories (with FTS5), entities, relationships.
  Uses Cellar's database but bypasses collection API for entity graph, JSON
  `entity_ids` arrays, and embedding BLOBs. Multi-agent prefix on table names.
- **Config**: `DurableMemoryConfig` — `mergeThreshold`, `decayRate`,
  `inactivePeriod`, `recallTopK`.

### ToolMemory (experimental)

Deterministic tracking of tool invocations — no LLM extraction needed.

- **Extraction**: Purely programmatic. Records tool name, parameters,
  success/failure, duration, and error messages from episodes with type
  `toolResult` or `error`. No LLM call required (ignores the `LlmCallback`
  passed to `consolidate()`).
- **Decay**: Medium — weeks. Successful patterns persist longer than failures.
- **Recall**: Returns relevant tool usage patterns for the current task context.
  "Last time this tool was called with these params, it failed because X."
- **Storage**: Structured records (not free-text). SQLite tables with columns,
  not blob content. Queryable by tool name, param patterns, success rate.
- **Advantage**: Cheapest component to run — no LLM cost, deterministic
  extraction, structured data.
- **Status**: Experimental. The concept has potential but may prove too
  restrictive in practice — structured tool records might not capture enough
  context to be useful at recall time, or the recall signal might be too noisy.
  The composable architecture means this can be swapped in/out freely for
  experimentation.

See: `agent-memory-systems-comparison.md` → Memory Types to Implement → Tool
Memory.

### Personality (special component)

Identity and evolving character — carried forward from v1.

- **Extraction**: LLM-driven personality update after sustained interaction.
  Conservative drift detection.
- **Decay**: Identity never decays. Personality evolves but doesn't decay.
- **Recall**: Always injected (not query-dependent). Fixed budget allocation.
- **Storage**: Persistent with history/rollback.
- **Future experiment — self-editing**: Inspired by Letta/MemGPT's self-editing
  pattern. Rather than purely programmatic personality updates, the agent could
  be prompted with "what did you feel about this?" or "what is your opinion?"
  to drive more expressive personality drift. Not a priority — the composable
  architecture means this can be swapped in as an alternative Personality
  component without affecting other components. See: Letta resources in
  `agent-memory-systems-comparison.md`.

### Procedures (special component)

Static operational playbooks — carried forward from v1.

- **Extraction**: None (author-defined, not learned from episodes).
- **Decay**: None.
- **Recall**: Keyword-matched against query. Injected when relevant.
- **Storage**: In-memory from configuration.

### ReinforcementMemory (experimental)

Success/failure reinforcement learning — tracks what worked and what didn't.

This is a fundamental learning mechanism in biological systems: positive
outcomes reinforce the behaviors that led to them, negative outcomes suppress
them. For an agent, this means learning from the outcomes of its own actions
across sessions.

- **Extraction**: After task completion (or failure), an LLM prompt evaluates
  the approach taken: "What strategy was used? Did it succeed or fail? What
  was the outcome?" Captures strategy → outcome pairs, not raw tool calls.
- **Decay**: Slow for strongly reinforced patterns. Fast for weakly-held or
  contradicted patterns. Reinforcement strengthens with repetition — a strategy
  that succeeds three times decays much slower than one that succeeded once.
- **Recall**: When the current task resembles a previously attempted task,
  surface the reinforced strategies: "This approach worked well last time" or
  "This approach failed — consider alternatives." Intent-matched, not
  keyword-matched.
- **Storage**: Strategy records with outcome valence (positive/negative),
  confidence (repetition count), and context tags. SQLite with structured
  fields.
- **Distinction from ToolMemory**: ToolMemory tracks individual tool
  invocations deterministically. ReinforcementMemory tracks higher-level
  strategies and their outcomes via LLM evaluation — "breaking the problem
  into smaller files worked" vs "tool X was called with params Y."
- **Status**: Experimental. This is a big area for exploration. The composable
  architecture means it can be developed and tested independently. Key open
  questions: how to define "strategy" granularity, how to attribute outcomes
  to strategies when multiple factors contributed, and how to handle
  contradictory signals (strategy X worked in context A but failed in context B).

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Component independence | Fully independent — no cross-component awareness | Simpler to reason about, test, and swap. Cross-component hooks are a future extension if needed. |
| Parallel execution | `Future.wait()` for consolidation and recall | Components are independent — no ordering dependency. Parallel execution reduces latency proportionally to the number of components. |
| Duplication across components | Allowed, labeled by source | Reinforces important information from different temporal perspectives. The dog-bite principle: knowing a long-term fact (dogs bite) and a short-term fact (got bit yesterday) together creates appropriate urgency. |
| Mixer role | Rebalance + report, not enforce | Components self-enforce their own budgets. Mixer normalizes scores across heterogeneous component scales and reports per-component budget usage. Engine can flag components that consistently exceed allocation. |
| Mixer intelligence | Weighted scoring formula, no LLM call | LLM calls are expensive and risk diluting content through pre-interpretation. Composable design makes it easy to experiment with smarter mixers later. |
| Token counting | Shared `Tokenizer` owned by engine | Components must use the engine's tokenizer (proper implementation or char/4 fallback) for consistent budget accounting. Passed through `ComponentBudget`. |
| Scoring semantics | Component-local, not cross-component comparable | Each component defines its own scoring scale. The mixer rebalances across scales — its config is an algorithm, not just numbers. |
| Budget enforcement | Components self-enforce, report usage | Components know their content best. Engine validates but trusts components. Dynamic allocation is a future enhancement to the Budget class. |
| Episode marking | Engine marks episodes consolidated after all components run | Components don't "claim" episodes exclusively. Multiple components can extract from the same episode. |
| Recall labeling | Every item tagged with component name | Enables the LLM to see provenance: "task-memory: X" vs "long-term-memory: Y". Experimental — label format may evolve based on LLM response quality. |
| Temporal validity | On stored items, not recall output | `validAt`/`invalidAt` timestamps belong on each component's internal storage. `recall()` filters out invalidated items — the mixer never sees them. |
| Engine lifecycle | `close()` propagates to all components | `Souvenir.close()` calls `Future.wait()` on all component `close()` methods for clean shutdown. |

---

## Patterns from External Systems

Drawn from research in `agent-memory-systems-comparison.md`. These are patterns
worth adopting or experimenting with — not all are needed immediately.

### Temporal Validity (from Zep/Graphiti)

Add `validAt` and `invalidAt` timestamps to **stored memory items** within each
component. Instead of relying solely on gradual decay, a component can
explicitly invalidate memories when their context ends. These timestamps live on
the component's internal storage records — not on `LabeledRecall`. A component's
`recall()` method filters out invalidated items before returning, so the mixer
never sees them.

```dart
// Internal to a component's storage — NOT on LabeledRecall
class StoredMemoryItem {
  final String content;
  final double importance;
  final DateTime createdAt;
  final DateTime? validAt;
  final DateTime? invalidAt;  // null = still valid
  // ... component-specific fields
}
```

**Application**: `TaskMemory` marks its extractions with
`invalidAt: sessionEnd`. On recall, it filters out items where
`invalidAt != null && invalidAt.isBefore(now)`. No slow decay needed — task
context is explicitly bounded.

This is lightweight: two columns on a SQLite table, no graph database required.
Gets 80% of Zep's temporal value at 5% of the complexity.

- [Graphiti GitHub](https://github.com/getzep/zep)
- [Research Paper: arXiv 2501.13956](https://arxiv.org/abs/2501.13956)

### Conflict Resolution (from Mem0)

Within a single component, new facts should be compared against existing entries
during consolidation:

- **Duplicate**: merge, keep higher importance
- **Contradiction**: new fact overrides old, old is invalidated (not deleted)
- **Update**: new fact refines old, content is merged

Each component implements its own conflict resolution strategy. The engine does
not prescribe one — `TaskMemory` might freely overwrite, while `DurableMemory`
might require high confidence before overriding an established fact.

- [Mem0 GitHub (Apache 2.0)](https://github.com/mem0ai/mem0)
- [Research Paper: arXiv 2504.19413](https://arxiv.org/abs/2504.19413)

### Auto-Flush Before Context Pressure (from OpenClaw)

When the agent's context window approaches capacity (before compaction or
summarization), trigger consolidation first. This prevents important in-context
information from being lost to summarization before components have a chance to
extract it.

This could be a lifecycle hook on the engine:

```dart
// Pseudocode — triggered by the agent runtime
souvenir.onContextPressure(() async {
  await souvenir.flush();
  await souvenir.consolidate(llm);
});
```

- [OpenClaw Memory Docs](https://docs.openclaw.ai/concepts/memory)
- [Architecture Guide](https://vertu.com/ai-tools/openclaw-clawdbot-architecture-engineering-reliable-and-controllable-ai-agents/)

---

## Multi-Agent Tenancy

The memory system should be self-contained and replicable per agent. Different
agents have different memory needs:

- A **primary agent** has broad understanding — durable preferences, long
  environmental memory, rich personality.
- A **coding subagent** needs strong task memory and tool memory but minimal
  long-term recall — it operates in focused bursts.
- A **research agent** might emphasize environmental memory and durable facts
  but skip task memory entirely.

Instead of handing tasks to "dumb" subagents with no memory, each agent owns
its own Souvenir instance configured with the appropriate components. This also
helps filter noise — a coding agent's task memory doesn't pollute the primary
agent's recall.

### Agent-Level Configuration

The component list, budget allocation, mixer weights, and per-component config
belong in an agent definition, not in a global config:

```dart
// Pseudocode — agent definition owns memory configuration
final codingAgent = AgentDefinition(
  name: 'coding',
  memory: Souvenir(
    components: [
      TaskMemory(decay: Duration(hours: 2)),
      ToolMemory(),
      Procedures(playbooks: codingPlaybooks),
    ],
    budget: Budget(
      totalTokens: 2000,
      allocation: {'task': 1000, 'tool': 600, 'procedures': 400},
    ),
    mixer: WeightedMixer(
      weights: {'task': 1.5, 'tool': 1.0, 'procedures': 0.8},
    ),
  ),
);

final primaryAgent = AgentDefinition(
  name: 'primary',
  memory: Souvenir(
    components: [
      TaskMemory(decay: Duration(hours: 8)),
      EnvironmentalMemory(decay: Duration(days: 14)),
      DurableMemory(),
      ToolMemory(),
      Personality(identity: primaryIdentity),
      Procedures(playbooks: generalPlaybooks),
    ],
    budget: Budget(
      totalTokens: 4000,
      allocation: {
        'task': 800, 'environmental': 800, 'durable': 1000,
        'tool': 400, 'personality': 600, 'procedures': 400,
      },
    ),
    mixer: WeightedMixer(
      weights: {
        'task': 1.2, 'environmental': 1.0, 'durable': 1.5,
        'tool': 0.8, 'personality': 1.0, 'procedures': 0.8,
      },
    ),
  ),
);
```

### Storage Isolation ✅

Implemented via `SouvenirCellar` — a factory that takes a shared `Cellar`
instance and an `agentId`. All collection names and table names are prefixed
with `{agentId}_` (e.g., `researcher_episodes`, `coder_task_items`). This
gives full data isolation in a shared database without requiring separate DB
files per agent.

Encryption enforcement: `SouvenirCellar(requireEncryption: true)` checks
`PRAGMA cipher_version` at construction time and throws `StateError` if
SQLCipher is not active. Designed to fail early in production rather than
silently storing unencrypted memory data.

### Cross-Agent Memory Sharing (future)

If two agents need to share knowledge (e.g., a research agent's findings
should be available to the primary agent), this could be modeled as:

- A shared `DurableMemory` component registered in both agents
- An explicit "publish to parent" API after task completion
- A read-only "reference memory" component that queries another agent's store

Decision deferred — start with full isolation, add sharing if needed.

---

## Open Questions

### Session / Lifecycle Boundaries

Task memory needs to know when tasks begin and end. This is a cross-cutting
concern that connects to the broader agent lifecycle:

- What constitutes a session? (Login, conversation break, topic switch)
- What metadata should episodes carry about lifecycle state?
- Should consolidation receive lifecycle context beyond raw episodes?
- How do session boundaries affect different components differently?

This needs its own design thinking and should not be baked into the memory
component interface prematurely. For now, components receive episodes with
timestamps and session IDs, and infer boundaries from those signals.

### Mixer Experimentation

The weighted mixer is a starting point. Future experiments:

- Query-aware weighting (debugging queries boost task memory weight)
- LLM-powered mixing for complex intent disambiguation
- Learned weights based on user feedback or outcome tracking
- Deduplication strategies (exact match, semantic similarity, or none)

### Storage Backend per Component — RESOLVED

Each component has dual store implementations behind an abstract interface:

- **In-memory stores** — for unit tests and lightweight usage. No external
  dependencies.
- **Cellar-backed stores** — for production. Use Cellar's `CollectionService`
  for CRUD + FTS5 search, with `cellar.rawQuery()` escape hatch for computed
  updates (importance decay, access count bumps).
- **DurableMemoryStore** — special case. Uses raw `sqlite3.Database` directly
  (via `cellar.database`) because it needs entity graph tables, `json_each()`
  queries, and embedding BLOBs that don't fit Cellar's collection model.

`SouvenirCellar` factory registers all collections and creates the appropriate
Cellar-backed store instances.

### Component-Specific Configuration — RESOLVED

Each component has its own immutable config class passed via constructor:

- `DurableMemoryConfig` — merge threshold, decay rate, inactive period, topK
- `TaskMemoryConfig` — max items per session, merge threshold, category weights,
  recency decay lambda, topK
- `EnvironmentalMemoryConfig` — max items, merge threshold, category weights,
  importance decay rate, floor threshold, inactive period, topK

Config classes use `const` constructors with sensible defaults. Components
accept optional config — `null` means use defaults.

---

## Migration from v1 — COMPLETE

The planned LegacyMemory wrapper approach was skipped. Instead, v2 components
were built directly against the new interfaces, and v1 code was deleted once
all three core components (DurableMemory, TaskMemory, EnvironmentalMemory)
were functional.

**What was deleted** (Phase 5, ~4,400 LOC):
- 22 v1 files: `config.dart`, `consolidation.dart`, `retrieval.dart`,
  `personality.dart`, `procedures.dart`, `souvenir.dart` (v1 facade),
  `sqlite_episode_store.dart`, all `store/*.dart` files (6 entities +
  generated code + schema + souvenir_store), all v1 model files
  (`entity.dart`, `memory.dart`, `recall.dart`, `relationship.dart`,
  `session_context.dart`), `docs/how-it-works.md`
- Dependencies removed: `stanza`, `stanza_sqlite`, `path`, `build_runner`,
  `stanza_builder` (16 transitive deps eliminated)

**What was kept** from v1: `Episode` model (unchanged), `LlmCallback` typedef,
`EmbeddingProvider` interface — all still used by v2 components.

---

## Phase Roadmap

Each phase is a shippable increment. Tests are written with the code in every
phase — not deferred.

### Phase 1: Core Interfaces + Engine Shell ✅

Build the v2 skeleton. All interfaces compile, the engine coordinates, and
tests validate the wiring with trivial stub components.

**Delivered:**
- `MemoryComponent` abstract class
- `LabeledRecall`, `ConsolidationReport` data classes
- `Tokenizer` abstract class + `ApproximateTokenizer` (char/4)
- `Budget`, `ComponentBudget` (with shared tokenizer reference)
- `Mixer` abstract class, `WeightedMixer` implementation
- `MixResult`, `BudgetUsage` data classes
- `Souvenir` v2 engine: component registration, `consolidate()` with
  `Future.wait()`, `recall()` with `Future.wait()`, `close()`
- Episode recording + flush (carried from v1), `InMemoryEpisodeStore`
- Stub `MemoryComponent` for testing (in-memory, deterministic)
- 88 tests

### Phase 2: DurableMemory ✅

Skipped the planned LegacyMemory wrapper — built DurableMemory directly
against the v2 interfaces.

**Delivered:**
- `DurableMemory` component with `DurableMemoryConfig`
- `DurableMemoryStore` — raw SQLite: memories (FTS5), entities, relationships
- `StoredMemory` with `validAt`/`invalidAt` temporal validity, `supersededBy`
- LLM extraction with conflict resolution (duplicate/contradiction/update)
- Entity graph: upsert, name matching, relationship traversal
- BM25 search, entity graph expansion for recall
- Embedding BLOB round-trip support
- Importance decay on inactive memories
- `SqliteEpisodeStore` (later replaced by `CellarEpisodeStore` in Phase 5)
- 131 tests (cumulative)

### Phase 3: TaskMemory ✅

**Delivered:**
- `TaskMemory` component with `TaskMemoryConfig`
- `TaskItem` model: goal/decision/result/context categories, session-scoped
- `InMemoryTaskMemoryStore` with Jaccard token similarity for `findSimilar()`
- Session boundary detection: new sessionId expires all previous session items
- `maxItemsPerSession` enforcement (evicts lowest importance)
- LLM extraction with `action: new|merge`
- Recall scoring: keyword overlap × category weight × recency decay + floor
- 175 tests (cumulative)

### Phase 4: EnvironmentalMemory ✅

**Delivered:**
- `EnvironmentalMemory` component with `EnvironmentalMemoryConfig`
- `EnvironmentalItem` model: capability/constraint/environment/pattern categories
- `InMemoryEnvironmentalMemoryStore` with Jaccard similarity
- Importance decay with configurable rate, floor threshold, inactive period
- No session boundary expiration (environmental knowledge persists)
- LLM extraction prompt focused on self-awareness and reflection
- 212 tests (cumulative)

### Phase 5: Cellar Integration + v1 Cleanup ✅

Replace Stanza with Cellar for all persistence. Delete dead v1 code.

**Delivered:**
- `CellarEpisodeStore` — Cellar collection CRUD for episode persistence
- `CellarTaskMemoryStore` — FTS5 search replaces Jaccard similarity
- `CellarEnvironmentalMemoryStore` — FTS5 search + raw SQL computed decay
- `DurableMemoryStore` refactored: `sqlite3.Database` (via `cellar.database`)
  with multi-agent table name prefixing
- `SouvenirCellar` factory: collection registration, `{agentId}_` prefixing,
  `requireEncryption` check via `PRAGMA cipher_version`
- v1 code deleted: 22 files, ~4,400 LOC removed
- Dependencies: `stanza`/`stanza_sqlite` → `cellar` (16 transitive deps gone)
- 240 tests (cumulative)

### Phase 6: Personality + Procedures — FUTURE

The original design planned these as v1 extractions. With v1 deleted, these
will be built fresh as new components.

**Candidates:**
- `Personality` — identity and evolving character. `consolidate()` drives
  personality drift. `recall()` always injects (not query-dependent). Fixed
  budget allocation. Possible self-editing experiment (Letta/MemGPT pattern).
- `Procedures` — static operational playbooks. Author-defined, not learned
  from episodes. Keyword-matched on recall.

### Phase 7: Experimental Components + Enhancements — FUTURE

Exploratory work. Each item is independent — can be tackled in any order,
dropped if unproductive, or developed in parallel.

**Candidates:**
- `ToolMemory` — deterministic tool invocation tracking. No LLM cost. May
  prove too restrictive (see design notes above).
- `ReinforcementMemory` — success/failure reinforcement learning. Strategy →
  outcome pairs via LLM evaluation. Big open questions around strategy
  granularity and outcome attribution.
- `ModelTokenizer` — proper token counting (tiktoken-equivalent for Dart).
  Replace `ApproximateTokenizer` for tighter budget control.
- Mixer experiments — query-aware weighting, distribution normalization,
  deduplication strategies.
- Cross-agent memory sharing — shared DurableMemory, "publish to parent" API,
  read-only reference components.

No fixed scope — this phase is ongoing experimentation enabled by the
composable architecture.

---

## Current File Layout

```
souvenir/
  lib/
    souvenir.dart                          ← barrel exports
    src/
      models/
        episode.dart                       ← Episode, EpisodeType, EpisodeStore
      durable/
        durable_memory.dart                ← DurableMemory component
        durable_memory_store.dart          ← Raw sqlite3 store (4 tables + FTS5)
        stored_memory.dart                 ← StoredMemory, MemoryStatus
      task/
        task_memory.dart                   ← TaskMemory component
        task_memory_store.dart             ← TaskMemoryStore interface + InMemory impl
        task_item.dart                     ← TaskItem, TaskItemCategory/Status
        cellar_task_memory_store.dart      ← Cellar-backed FTS5 impl
      environmental/
        environmental_memory.dart          ← EnvironmentalMemory component
        environmental_memory_store.dart    ← Store interface + InMemory impl
        environmental_item.dart            ← EnvironmentalItem, Category/Status
        cellar_environmental_memory_store.dart ← Cellar-backed FTS5 impl
      cellar_episode_store.dart            ← CellarEpisodeStore (Cellar CRUD)
      souvenir_cellar.dart                 ← SouvenirCellar factory
      souvenir.dart                        ← Souvenir engine
      memory_component.dart                ← MemoryComponent abstract class
      budget.dart                          ← Budget, ComponentBudget, Tokenizer
      mixer.dart                           ← Mixer, WeightedMixer, MixResult
      episode.dart                         ← re-export
      llm_callback.dart                    ← LlmCallback typedef
      embedding_provider.dart              ← EmbeddingProvider interface
  test/
    souvenir_test.dart                     ← 240 tests
  pubspec.yaml                             ← deps: cellar, ulid
```

## Relationship to v1 (DELETED)

| v1 Concept (deleted) | v2 Replacement |
|----------------------|----------------|
| `Souvenir` (monolithic facade) | `Souvenir` (engine + component registry) |
| `SouvenirStore` (single store) | Per-component stores via `SouvenirCellar` |
| `RetrievalPipeline` | `MemoryComponent.recall()` per component + `Mixer` |
| `ConsolidationPipeline` | `MemoryComponent.consolidate()` per component |
| `SouvenirConfig` | `Budget` + per-component config classes |
| `SessionContext` | `MixResult` from `Mixer` |
| `PersonalityManager` | Future: `Personality` component |
| `ProcedureManager` | Future: `Procedures` component |
| `SqliteEpisodeStore` (Stanza) | `CellarEpisodeStore` (Cellar) |
| Stanza entities + code gen | Raw SQL (`DurableMemoryStore`) + Cellar collections |
