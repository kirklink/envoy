# Agent Memory Systems Comparison

Research notes for Dart agent runtime memory implementation.

---

## OpenClaw (Current Inspiration)

**Philosophy:** File-first, markdown-is-truth. The agent only "remembers" what it writes to disk.

**How it works:**

- `MEMORY.md` for curated long-term facts (preferences, decisions, durable context)
- `memory/YYYY-MM-DD.md` daily logs, append-only
- Hybrid search: vector similarity (sqlite-vec) + BM25 keyword search (SQLite FTS5), scores fused together
- Temporal decay weighting so recent notes rank higher
- Auto-flush before context compaction — when the context window is about to be summarized, it triggers the agent to write important stuff to disk first

**Strengths:**

- Simplicity is ideal for a Dart port
- Markdown + SQLite is portable, fits the per-user Fly instance model perfectly
- No external services needed
- Auto-flush-before-compaction pattern is clever and directly relevant

**Weaknesses:**

- No automatic extraction — the agent has to explicitly decide to write memories
- Works for power users but may be unreliable for end users who don't prompt "remember this"
- Memory stored inside the context window can be destroyed by compaction or session restarts

**Resources:**

- [OpenClaw Memory Docs](https://docs.openclaw.ai/concepts/memory)
- [OpenClaw Architecture Guide](https://vertu.com/ai-tools/openclaw-clawdbot-architecture-engineering-reliable-and-controllable-ai-agents/)
- [Deep Dive: How OpenClaw's Memory System Works](https://snowan.gitbook.io/study-notes/ai-blogs/openclaw-memory-system-deep-dive)

---

## Mem0

**Philosophy:** Automatic extraction and consolidation. The system decides what's worth remembering, not the agent.

**How it works:**

- Two-phase pipeline:
  1. **Extraction Phase** — ingests the latest exchange plus a rolling summary plus recent messages, uses an LLM to extract candidate memories
  2. **Update Phase** — compares each new fact against similar entries in the vector database
- Resolves conflicts: new facts override old ones, duplicates get merged, contradictions get handled
- Priority scoring and contextual tagging decide what gets stored
- Dynamic forgetting decays low-relevance entries over time
- Three memory scopes: user (cross-session), session (current conversation), agent (per-agent instance)
- Hybrid storage: vector + graph + key-value stores
- Apache 2.0 licensed, or hosted SaaS

**Strengths:**

- Automatic extraction is key for "proactively helps" — users shouldn't have to manage their own memory
- Three-scope model (user/session/agent) maps well to an architecture where agents serve users but also learn tool patterns independently
- Conflict resolution and deduplication logic is battle-tested
- 26% higher response accuracy vs OpenAI memory, 90% fewer tokens than full-context approaches (per their ECAI-accepted research)

**Weaknesses:**

- Requires LLM calls for extraction (cost per interaction)
- Python/JS SDKs would need a full Dart port
- Graph memory variant adds complexity

**Resources:**

- [Mem0 GitHub (Apache 2.0)](https://github.com/mem0ai/mem0)
- [Research Paper: arXiv 2504.19413](https://arxiv.org/abs/2504.19413)
- [Mem0 Research Blog](https://mem0.ai/research)
- [Mem0 Docs](https://docs.mem0.ai/platform/overview)
- [DataCamp Tutorial](https://www.datacamp.com/tutorial/mem0-tutorial)

---

## Zep (Graphiti)

**Philosophy:** Temporal knowledge graph. Facts aren't just stored — they have `valid_at` and `invalid_at` timestamps, tracking how knowledge evolves.

**How it works:**

- Ingests from conversations, JSON business data, and documents
- Automatically extracts entities, relationships, and facts
- Builds a knowledge graph where nodes are entities and edges are relationships with temporal metadata
- When facts change, old ones are invalidated but preserved — the agent can reason about what *used to be* true
- Maintains multiple temporal versions of facts, traces lineage of information changes
- Retrieval combines graph traversal + semantic embedding search + community detection
- Graphiti (the core engine) is open source

**Strengths:**

- Temporal aspect is genuinely different — if a user's API endpoint changes, the agent knows both current and previous configuration
- For tool patterns, can track which tools worked at different points in time and correlate with API version changes
- "What changed and when" capability that other systems don't do well
- Sub-200ms retrieval latency
- Up to 18.5% accuracy improvement over baselines on LongMemEval benchmark

**Weaknesses:**

- Graph databases add infrastructure complexity
- Temporal model may be overkill for early-stage implementations
- Graphiti engine is Python-based — hardest to port to Dart

**Resources:**

- [Zep Platform](https://www.getzep.com/)
- [Graphiti GitHub (open source)](https://github.com/getzep/zep)
- [Research Paper: arXiv 2501.13956](https://arxiv.org/abs/2501.13956)
- [Zep State of the Art Blog Post](https://blog.getzep.com/state-of-the-art-agent-memory/)
- [Agent Memory Product Page](https://www.getzep.com/product/agent-memory/)

---

## Letta (formerly MemGPT)

**Philosophy:** Self-editing memory — the agent manages its own memory via tools, similar to an OS managing virtual memory.

**How it works:**

- Two tiers: in-context "core memory" (analogous to RAM) pinned in the context window, and out-of-context "archival memory" (analogous to disk)
- Agent gets explicit tools: `memory_replace`, `memory_insert`, `memory_rethink` for core memory, plus `archival_memory_insert/search` for long-term storage
- When context window reaches capacity, intelligent eviction strategies summarize and store important details before removing them
- Recursive summarization — older messages have progressively less influence
- Agent explicitly reasons about its own memory management
- Agents treated as persistent microservices with all state stored in a DB
- Recently transitioning from MemGPT-style architecture to a simpler "Letta V1" architecture optimized for newer reasoning models

**Strengths:**

- OS analogy fits well with per-user isolated instance architecture
- "Agent-as-a-service" pattern with persistent state maps directly to per-user Fly instances
- Self-editing approach means the agent learns how to manage memory over time
- "Skill learning" feature — dynamically learning skills through experience — is conceptually similar to a tool voting mechanism
- Model-agnostic, supports multiple LLM providers

**Weaknesses:**

- Self-editing quality depends entirely on the LLM's judgment about what to remember
- Smaller/cheaper models may make poor memory management decisions
- Recent move away from original MemGPT architecture toward simpler patterns suggests the complexity may not have been worth it
- Heartbeat/tool-chaining patterns are being deprecated in favor of native model capabilities

**Resources:**

- [Letta Platform](https://www.letta.com/)
- [Letta GitHub](https://github.com/letta-ai/letta)
- [MemGPT Research Paper](https://arxiv.org/abs/2310.08560)
- [Agent Memory Blog Post](https://www.letta.com/blog/agent-memory)
- [Letta V1 Architecture Blog](https://www.letta.com/blog/letta-v1-agent)
- [Letta Docs — Key Concepts](https://docs.letta.com/concepts/)

---

## Recommendations for Dart Agent Runtime

Given constraints: Dart-native, per-user isolation, SQLite-backed, designed for AI consumption.

### 1. Start with OpenClaw's file-first pattern
Already in progress. Markdown + SQLite is the right foundation for per-instance simplicity.

### 2. Add Mem0-style automatic extraction
Don't rely on the agent to explicitly "remember." Run extraction after each exchange, comparing against existing facts. This is the piece that makes it "proactively helpful."

### 3. Borrow Zep's temporal validity concept
Even a simple `valid_from`/`invalid_at` on extracted facts gives agents the ability to handle changing configurations. No need for a full graph DB — SQLite with structured fact tables gets 80% of the value.

### 4. Skip full MemGPT self-editing pattern for now
It adds complexity and depends heavily on the LLM being good at meta-reasoning about memory. The framework should manage memory programmatically where possible and only ask the LLM for extraction.

### Key Insight

Across all four systems, **the extraction problem is the hard part.** Getting an LLM to reliably identify what's worth remembering from a conversation — without storing garbage or missing important facts — is where all these systems invest the most engineering. That's where the Dart implementation effort should focus.

---

## Memory Types to Implement

Based on cross-referencing all four systems, these are the memory categories relevant to the agent runtime:

| Memory Type | Description | Storage Pattern |
|---|---|---|
| **Semantic** | Extracted facts, preferences, patterns | SQLite + embeddings |
| **Procedural** | Learned workflows ("user usually wants X before Y") | Structured records |
| **Tool Memory** | Which tools worked for which tasks, with what parameters | Deterministic — structured data from tool invocations |
| **Session/Buffer** | Recent conversation context | In-memory, evicted on compaction |
| **Episodic** | What happened in past sessions | Summarized transcripts |

Tool memory has a natural advantage: tool invocations are structured data. Success/failure, input patterns, frequency can be tracked deterministically without needing LLM extraction.
