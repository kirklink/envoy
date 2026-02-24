# Tuning Results

**Grid:** fts=[0.5, 1.0, 1.5, 2.0]  vec=[0.5, 1.0, 1.5, 2.0, 2.5, 3.0]  entity=[0.3, 0.5, 0.8, 1.0, 1.5]
**Total combinations:** 120

## Best Config

```
fts=0.5  vec=0.5  entity=0.3
```

## Full Report

# Souvenir Recall Evaluation

**Run:** 2026-02-24 21:50:49Z  
**Config:** fts=0.5  vec=0.5  entity=0.3  threshold=0.05  
**Embeddings:** fake

## Summary

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

## Scenario Details

### semantic_bridge

> Queries with no keyword overlap must bridge to memories via vector similarity. The classic failure mode of pure FTS-based recall.

✅ **`favourite animal`** — "favourite animal" → rabbit memory via vector (no FTS match)

Expected `rabbits` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | User thinks rabbits are the most adorable creatures | 0.449 | 0.00 | 1.00 | 0.00 |

✅ **`cute pets`** — "cute pets" → rabbit memory via vector similarity

Expected `rabbits` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | User thinks rabbits are the most adorable creatures | 0.478 | 0.00 | 0.99 | 0.00 |
| 2 | User prefers dark mode in all development tools | 0.052 | 0.00 | 0.17 | 0.00 |

✅ **`preferred programming language`** — "preferred programming language" → Dart memory via vector

Expected `Dart` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Project uses Dart 3.7 as the primary language | 0.699 | 1.00 | 1.00 | 0.00 |
| 2 | Alice is the project lead and prefers pair programming | 0.630 | 0.80 | 1.00 | 0.00 |
| 3 | Current goal is to build REST API endpoints for user mana... | 0.373 | 0.00 | 0.93 | 0.00 |
| 4 | Decided to use shelf as the HTTP framework | 0.335 | 0.00 | 0.96 | 0.00 |
| 5 | Dart SDK version 3.7.0 is installed and available on PATH | 0.299 | 0.00 | 1.00 | 0.00 |

### fts_direct

> Queries with direct keyword overlap rely primarily on BM25 FTS signal.

✅ **`REST API`** — "REST API" → task goal via exact FTS match

Expected `REST API endpoints` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Current goal is to build REST API endpoints for user mana... | 0.800 | 1.00 | 1.00 | 0.00 |
| 2 | Decided to use shelf as the HTTP framework | 0.345 | 0.00 | 0.99 | 0.00 |
| 3 | Alice is the project lead and prefers pair programming | 0.326 | 0.00 | 0.93 | 0.00 |
| 4 | Project uses Dart 3.7 as the primary language | 0.322 | 0.00 | 0.92 | 0.00 |
| 5 | Dart SDK version 3.7.0 is installed and available on PATH | 0.276 | 0.00 | 0.92 | 0.00 |

✅ **`JWT tokens`** — "JWT tokens" → authentication result via FTS

Expected `JWT tokens` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Authentication endpoint returns JWT tokens on success | 0.581 | 1.00 | 0.81 | 0.00 |
| 2 | User prefers dark mode in all development tools | 0.321 | 0.00 | 1.00 | 0.00 |
| 3 | Running on Linux x86_64 with 16GB RAM | 0.267 | 0.00 | 1.00 | 0.00 |
| 4 | Decided to use shelf as the HTTP framework | 0.133 | 0.00 | 0.36 | 0.00 |
| 5 | Current goal is to build REST API endpoints for user mana... | 0.129 | 0.00 | 0.30 | 0.00 |

✅ **`PostgreSQL JSONB`** — "PostgreSQL JSONB" → durable fact via FTS

Expected `PostgreSQL 16` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | PostgreSQL 16 is the production database with JSONB columns | 1.112 | 1.00 | 1.00 | 1.00 |
| 2 | Project uses Dart 3.7 as the primary language | 0.198 | 0.00 | 0.11 | 0.70 |
| 3 | Current goal is to build REST API endpoints for user mana... | 0.177 | 0.00 | 0.40 | 0.00 |
| 4 | Dart SDK version 3.7.0 is installed and available on PATH | 0.170 | 0.00 | 0.11 | 0.70 |
| 5 | Authentication endpoint returns JWT tokens on success | 0.125 | 0.00 | 0.38 | 0.00 |

### entity_expansion

> Querying for an entity name should expand to memories linked via the entity graph, including 1-hop relationships.

✅ **`Alice`** — "Alice" → memory about Alice via entity match

Expected `Alice` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Alice is the project lead and prefers pair programming | 0.599 | 1.00 | 0.11 | 1.00 |
| 2 | User prefers dark mode in all development tools | 0.300 | 0.00 | 1.00 | 0.00 |
| 3 | User thinks rabbits are the most adorable creatures | 0.267 | 0.00 | 0.05 | 0.90 |
| 4 | Running on Linux x86_64 with 16GB RAM | 0.250 | 0.00 | 1.00 | 0.00 |
| 5 | Authentication endpoint returns JWT tokens on success | 0.243 | 0.00 | 0.81 | 0.00 |

✅ **`rabbits`** — "rabbits" → rabbit memory via entity + FTS signals

Expected `rabbits` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | User thinks rabbits are the most adorable creatures | 1.251 | 1.00 | 1.00 | 1.00 |
| 2 | Alice is the project lead and prefers pair programming | 0.204 | 0.00 | 0.01 | 0.90 |

### multi_signal

> Memories matching on multiple signals (FTS + entity + vector) should rank above single-signal matches for the same query.

✅ **`Dart language`** — "Dart language" → durable Dart fact ranks above env Dart via multi-signal (FTS + entity + importance)

Expected `Dart 3.7` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Project uses Dart 3.7 as the primary language | 0.910 | 1.00 | 1.00 | 1.00 |
| 2 | Dart SDK version 3.7.0 is installed and available on PATH | 0.592 | 0.38 | 1.00 | 1.00 |
| 3 | Current goal is to build REST API endpoints for user mana... | 0.371 | 0.00 | 0.93 | 0.00 |
| 4 | Alice is the project lead and prefers pair programming | 0.350 | 0.00 | 1.00 | 0.00 |
| 5 | Decided to use shelf as the HTTP framework | 0.333 | 0.00 | 0.95 | 0.00 |

✅ **`database queries`** — "database queries" → PostgreSQL memory via FTS + entity + vector

Expected `PostgreSQL 16` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | PostgreSQL 16 is the production database with JSONB columns | 0.855 | 1.00 | 1.00 | 0.00 |
| 2 | Current goal is to build REST API endpoints for user mana... | 0.181 | 0.00 | 0.42 | 0.00 |
| 3 | Authentication endpoint returns JWT tokens on success | 0.137 | 0.00 | 0.43 | 0.00 |
| 4 | Decided to use shelf as the HTTP framework | 0.101 | 0.00 | 0.27 | 0.00 |

### component_weights

> When default component weights are used, durable facts (importance 0.7-0.9) should outrank lower-importance environmental observations for the same topic.

✅ **`Dart`** — Durable "Dart 3.7 as primary language" (importance 0.7) outranks environmental "Dart SDK installed" (importance 0.6)

Expected `Dart 3.7 as the primary language` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Project uses Dart 3.7 as the primary language | 0.910 | 1.00 | 1.00 | 1.00 |
| 2 | Dart SDK version 3.7.0 is installed and available on PATH | 0.737 | 0.86 | 1.00 | 1.00 |
| 3 | Current goal is to build REST API endpoints for user mana... | 0.368 | 0.00 | 0.92 | 0.00 |
| 4 | Alice is the project lead and prefers pair programming | 0.349 | 0.00 | 1.00 | 0.00 |
| 5 | Decided to use shelf as the HTTP framework | 0.329 | 0.00 | 0.94 | 0.00 |

### temporal_decay

> A recent memory with the same content should rank above an old memory with the same importance, due to temporal decay.

✅ **`preferred database`** — Recent memory should rank at position 1 (temporal decay penalises the 120-day-old duplicate)

Expected `Preferred database is PostgreSQL` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Preferred database is PostgreSQL | 0.799 | 1.00 | 1.00 | 0.00 |

### relevance_silence

> Completely unrelated queries should return no results above the relevance threshold (silence > noise).

✅ **`quantum entanglement`** — "quantum entanglement" should return empty (no relevant memories)

Expected: empty results. Got: empty ✓

✅ **`medieval history knights`** — "medieval history" should return empty (irrelevant to project context)

Expected: empty results. Got: empty ✓

### conversation_pipeline

> Simulates a multi-turn conversation: the store is seeded with memories that would have been consolidated from a realistic exchange (discussing a project, then an unrelated topic). Recall should surface the right memories despite topic mixing.

✅ **`what are we building`** — Project goal surfaces despite rabbit tangent in history

Expected `task management CLI` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | User is building a task management CLI in Dart | 0.447 | 1.00 | 0.05 | 0.00 |

✅ **`database choice`** — Technical decision recalled correctly

Expected `sqlite3` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | Chose sqlite3 package for local persistence | 0.375 | 0.00 | 1.00 | 0.00 |
| 2 | SQLite WAL mode enabled for concurrent reads | 0.300 | 0.00 | 1.00 | 0.00 |
| 3 | User is building a task management CLI in Dart | 0.054 | 0.00 | 0.12 | 0.00 |

✅ **`rabbit names`** — Off-topic personal fact recalled when directly queried

Expected `Mochi` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | User owns two rabbits named Mochi and Daisy | 0.350 | 0.00 | 1.00 | 0.00 |
| 2 | User feeds rabbits pellets and hay twice a day | 0.250 | 0.00 | 1.00 | 0.00 |

✅ **`experience with SQLite and Dart`** — Durable user-knowledge fact surfaces via FTS overlap ("Dart", "SQLite")

Expected `Dart well` at rank 1. Got rank: **1** (RR: 1.00)

| Rank | Content (truncated) | Score | FTS | Vec | Entity |
|---|---|---|---|---|---|
| 1 | User knows Dart well but is new to SQLite | 0.800 | 1.00 | 1.00 | 0.00 |
| 2 | User is building a task management CLI in Dart | 0.708 | 0.50 | 1.00 | 0.00 |
| 3 | SQLite WAL mode enabled for concurrent reads | 0.184 | 0.45 | 0.12 | 0.00 |
| 4 | User owns two rabbits named Mochi and Daisy | 0.157 | 0.42 | 0.00 | 0.00 |
| 5 | User feeds rabbits pellets and hay twice a day | 0.112 | 0.42 | 0.00 | 0.00 |

