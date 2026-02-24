# Souvenir v2 Experiment Log

Running record of configuration changes and observed outcomes from the Memory Lab experiments.

## Test Protocol

Same conversation pattern each session:
1. Greeting + "what can you do?" (2 turns)
2. Dart function questions — sum 5 numbers, list approach, multiply 5 numbers (3 turns)
3. Topic shift to rabbits — "what do you think about rabbits?", "they are cute", "what do they eat?", "just curious" (4 turns)
4. Consolidation
5. Post-consolidation probes — repeat message, "what are you best at?", "what is my favourite animal?" (2-3 turns)

Key test: Turn 12 query "what would you say my favourite animal is?" — does durable recall surface the rabbits memory via semantic match (no keyword overlap)?

---

## Session 1 — Baseline (no embeddings, no mixer normalization)

**Date**: 2026-02-24
**Session ID**: ses_1771946513239

### Config
- Embeddings: none
- Mixer normalization: none
- rrfK: 60
- Durable importance for rabbits: 0.50

### Turn 12 Recall — "favourite animal" query
| Rank | Component | Score | Content |
|------|-----------|-------|---------|
| 1 | durable | 0.013 | User prefers list-based approaches... |
| 2 | durable | 0.011 | User is considering Dart for server-side... |
| 3 | task | 0.061 | User wants to learn Dart programming... |
| ... | | | |
| 6 | durable | (not ranked) | User finds rabbits cute... — **not in recall at all** |

### Observations
- Durable rabbit memory not recalled — FTS5 cannot bridge "favourite animal" → "rabbits"
- Durable memories ranked last due to score scale mismatch (RRF 0.01-0.05 vs Jaccard 0-1)
- All recall dominated by task + environmental

---

## Session 2 — Mixer normalization (no embeddings)

**Date**: 2026-02-24
**Session ID**: ses_... (second session in same conversation)

### Config change
- Mixer normalization: **added** (per-component score normalization before weighting)
- Everything else unchanged

### Turn 12 Recall — "favourite animal" query
| Rank | Component | Score | Content |
|------|-----------|-------|---------|
| 1 | durable | 0.013 | User prefers list-based approaches... |
| 2 | durable | 0.011 | User is considering Dart for server-side... |
| 3 | task | 0.061 | User wants to learn Dart programming... |
| ... | | | |
| 11 | durable | 0.014 | User finds rabbits cute... |

### Observations
- Mixer normalization fixed cross-component ranking (durable items ranked 1-2 overall)
- But within durable, rabbit memory still ranked last — FTS5 keyword gap unchanged
- The normalization helped durable compete with task/environmental, but didn't help the semantic gap

---

## Session 3 — Embeddings added (Ollama all-minilm)

**Date**: 2026-02-24
**Session ID**: ses_1771953810975

### Config change
- Embeddings: **all-minilm (384 dims, Ollama)**
- OllamaEmbeddingProvider wired into DurableMemory
- rrfK: 60 (unchanged)

### Raw vector similarity (standalone test)
| Cosine | Memory |
|--------|--------|
| 0.3729 | User finds rabbits cute... |
| 0.0870 | User needed Dart function to multiply... |
| 0.0126 | User interested in Dart programming... |

Vector signal correctly identifies rabbits as 4-30x more relevant.

### Turn 12 Recall — "favourite animal" query
| Rank | Component | Score | Content |
|------|-----------|-------|---------|
| 1 | durable | 0.043 | User is interested in Dart programming... |
| 2 | task | 0.064 | User wants to write a Dart function... |
| 3 | task | 0.064 | User needs a Dart function that multiplies... |
| 4 | durable | 0.034 | **User finds rabbits cute...** |
| 5 | durable | 0.033 | User needed a Dart function to multiply... |

### Observations
- Rabbit memory improved: rank 11 → rank 4, score 0.014 → 0.034 (2.4x)
- Vector signal IS firing — confirmed via standalone test and /api/recall endpoint
- But RRF with k=60 flattens rank differences: rank 1 = 0.0164, rank 3 = 0.0159 (only 3% gap)
- Dart memory at rank 1 despite zero semantic relevance because:
  - BM25 + entity graph give it ranks in 2/3 signals
  - Higher importance (0.80 vs 0.50) amplified by `_applyScoreAdjustments`
  - `accessCount` multiplier further boosts frequently-accessed items
- **Root cause**: RRF k=60 is too flat — strong rank-1 vector signal barely outweighs weak BM25 matches

### Identified tuning levers
1. **Lower rrfK** (e.g., 10) — rank-1 gets 0.091 vs rank-3 at 0.077 (18% gap vs current 3%)
2. **Importance assignment** — rabbits at 0.50 vs Dart at 0.80 is the LLM's judgment, may need prompt tuning
3. **Signal weighting in RRF** — currently all 3 signals weighted equally; could weight vector higher

---

## Session 4 — Lower rrfK (k=10)

**Date**: 2026-02-24
**Session ID**: ses_1771954932246

### Config change
- rrfK: 60 → **10**
- Everything else unchanged (embeddings still on)

### Turn 11 Recall — "favourite animal" query
| Rank | Component | Score | Content |
|------|-----------|-------|---------|
| 1 | durable | 0.236 | User is interested in Dart programming... |
| 2 | durable | 0.091 | User has a current use case for summing... |
| 3 | durable | 0.062 | **User finds rabbits cute...** |
| 4 | task | 0.060 | User needs a Dart function to multiply... |
| 5 | task | 0.052 | User wants to write a Dart function... |

### Observations
- **Worse than k=60**: gap between Dart (0.236) and rabbits (0.062) widened to 3.8x (was 1.3x)
- Lower k amplified multi-signal advantage: Dart appears in BM25 + entity graph + weak vector (3 signals), rabbit only in vector (1 signal)
- RRF fundamentally rewards breadth of signal presence over strength of any single signal
- Even with perfect vector ranking, a memory in 1 signal cannot beat one in 3 signals under RRF

### Architectural conclusion
The per-component recall architecture is the root problem, not RRF tuning:
- Each component recalls independently (top-K from its own index)
- DurableMemory's internal RRF discards score magnitude — cosine 0.37 and 0.01 both become rank positions
- Task and environmental components use Jaccard (keyword-only), guaranteeing noise items appear in recall
- Self-reinforcing environmental memories inflate environmental's contribution

**Decision**: Pivot to unified recall — consolidation stays component-based, but recall queries a single index across all memories.

---

## Experiment Conclusions

After 4 sessions testing different configurations:
1. Mixer normalization fixed cross-component score scale mismatch
2. Embeddings correctly identify semantic relevance (cosine 0.37 for rabbits vs 0.01 for Dart)
3. Per-component recall with RRF fusion fundamentally cannot surface a strong single-signal match over weak multi-signal noise
4. The component boundary is orthogonal to query relevance

**Next step**: New design spec for unified-recall architecture. Consolidation remains pluggable/component-based; recall becomes a single search across all stored memories with component tag as metadata.
