# LLM Context Broker — Concept Exploration

A conversational exploration of a developer tool idea: a persistent, context-aware agent that sits between the developer and their LLM, eliminating the overhead of context management across coding sessions.

---

## Starting Point: What Would an Expert Developer Build?

A CLI that watches your project, infers what you're trying to do from recent file changes and git history, and suggests the next logical step (or just does it). A context-aware dev copilot that lives in your terminal and doesn't need you to explain anything.

The motivation: the most annoying part of development isn't writing code — it's the constant context-switching and remembering where you left off.

---

## The Original Idea

A terminal-resident agent that passively watches your project and builds a mental model of what you're doing — so you never have to re-explain context.

### How It Works

It monitors a few signals continuously: git diffs (what changed recently), file system events (what you're touching right now), your shell history (what commands you've been running), and optionally your editor state. From these, it infers your current task, your intent, and where you are in the workflow.

### What It Gives You

- **"Where was I?"** — You come back after lunch or the next morning, type `ctx` and it says: *"You were refactoring the auth middleware. You'd updated 3 of 5 route handlers. The remaining two are `/api/billing` and `/api/admin`. Your last failing test was `test_admin_requires_token`."*
- **"What's next?"** — It suggests the most logical next action based on patterns. If you've been doing repetitive refactors across files, it queues up the next one. If your tests are failing, it surfaces the error.
- **"Just do it"** — For mechanical, low-risk tasks (updating imports after a rename, regenerating types, running the obvious fix), it can execute with your approval.

### What Makes It Different From Existing Copilots

Most AI dev tools are *reactive* — you ask, they answer. This one is *proactive* and *persistent*. It accumulates context over hours/days rather than starting fresh each prompt. It's closer to a junior dev who's been pair-programming with you all week and actually remembers what happened Monday.

### The Tricky Parts

- Keeping the context model accurate without it drifting or hallucinating intent
- Knowing when to suggest vs. stay quiet (nobody wants a clippy in their terminal)
- Privacy — it needs to be fully local, no shipping your code anywhere
- Making the inference fast enough that it doesn't slow down your workflow

### Stack Considerations

Local LLM (something small and fast, like a quantized model) for inference, SQLite for the context store, filesystem watchers for real-time events, and a simple TUI for interaction. Ship it as a single binary if possible.

---

## Proactivity Spectrum

### Level 1: Narration
It maintains a running summary of what you're doing. You ask, it tells. Low risk, immediately useful. The core research question: can you reliably infer *task intent* from file changes and shell history?

### Level 2: Anticipation
It starts predicting. You delete a function — it flags all the call sites before your linter even runs. You create a new route — it drafts the test file, the types, the boilerplate. It notices you've been manually running `make build && make test` after every change and offers to set up a watch loop. It's pattern-matching on *your* habits, not generic best practices.

### Level 3: Interruption
It speaks up uninvited when confidence is high. "You've been editing this file for 20 minutes without running tests — want me to run them?" Or "This function you're writing looks very similar to `utils/parse.ts:47` — reuse?" The clippy risk lives here, so the threshold for speaking up needs careful tuning.

### Level 4: Autonomous Action
It just does things in the background. Auto-formats on save, auto-commits WIP snapshots, keeps a scratch branch synced, pre-runs tests on the files you're touching, pre-fetches docs for libraries you just imported. You don't interact with it — you just notice things are already done.

### Level 5: Strategic
It reads your open issues/PRs, correlates them with what you're coding, and suggests prioritization. "You've been working on feature X for 3 days but there's a critical bug filed 2 hours ago on the module you touched yesterday — you're probably the fastest person to fix it." Basically a project manager that actually understands the code.

### Where to Experiment First

Levels 1–2 are the sweet spot for a prototype. A minimal experiment: watch git diffs + file events for a day of real work, then ask the model to narrate what happened. Compare its narration to your actual memory. That tells you immediately how viable the whole idea is.

---

## Code Writing Enhancement

### Context Quality Determines Code Quality

Current copilots generate code from a narrow window — the current file, maybe a few open tabs. This tool would have a much richer context built up over time.

- **Pre-seeded generation** — You create a new file. Before you type anything, it already knows *why* — because it saw you reading a related module, failing a test, or discussing it in a commit message. Instead of writing a comment prompt, it already has the intent and can offer a full draft.
- **Consistency enforcement** — Not linting rules — *patterns*. It's seen how you handle errors across 40 files. When you write a new error handler, it matches the shape of what you've been doing everywhere else.
- **Multi-file coherence** — Real coding tasks span files. The tool knows the full change set because it's been watching the pattern. When you finish a model change, it drafts the ripple effects across all downstream files at once.
- **Friction-point detection** — It notices when you're struggling — rewriting the same block, undoing changes, switching between files rapidly. It offers help referencing your own codebase as precedent.

---

## The Reframe: LLM-First Workflow

### The Challenge

When working with an LLM that writes most of the code, watching how *the developer* works isn't the bottleneck. The developer isn't the coder — they're the director. The real bottleneck is the back-and-forth with the LLM.

### The Revised Idea: Context Broker

The tool sits *between the developer and the LLM*, not between the developer and the code.

**Context broker.** It maintains a persistent, structured understanding of the project — architecture, conventions, decisions made, things tried and failed. When you say "add rate limiting to the API," you just say that. The tool injects the right context: router structure, middleware composition patterns, existing auth approach, test conventions. The LLM gets a perfect brief every time without you doing the work.

**Session stitching.** You worked on the billing module yesterday across three LLM sessions. Today you say "continue with billing." The tool reconstructs the full arc — what was built, what's left, what issues came up — and feeds it forward. No more copy-paste recaps.

**Decision memory.** "We tried approach X for caching but it didn't work because of Y, so we went with Z." The tool captures these decisions as they happen and resurfaces them when relevant, so the LLM doesn't suggest the same dead-end twice.

**Output validation.** Before you even review LLM-generated code, the tool checks: does this match existing codebase patterns? Does it conflict with something from a previous session? Did it introduce a dependency that contradicts an earlier decision? A review layer that catches drift.

**Multi-session orchestration.** Big features span many LLM interactions. The tool tracks the overall plan, knows which pieces are done, and frames the next session's prompt automatically. You just say "next" and it knows what "next" means.

### The Shift

It's not a tool that watches *you* code. It's a tool that watches *the LLM* code, remembers everything across sessions, and makes you a more effective director by eliminating all the context management overhead. You focus purely on *what* to build and *why*. It handles *how to ask for it*.
