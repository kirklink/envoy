# Writing Clean Dart Code Without an IDE

Recommendations for Envoy agents (or any AI agent) producing Dart code outside
of an IDE environment like VSCode.

## The Problem

Inside VSCode with the Dart extension, Claude Code benefits from real-time
analyzer diagnostics, existing code context, and immediate feedback on type
errors, unused imports, missing overrides, etc. An autonomous Envoy agent
running outside an IDE has none of this. How do we close the gap?

Two things matter most:

1. **Static analysis** — the CLI equivalent of IDE diagnostics
2. **Framework knowledge** — conventions and patterns the analyzer can't enforce

## 1. Static Analysis as a Tool

`dart analyze` is the single highest-value tool for a code-writing agent. It
runs the same analysis engine as the VSCode Dart extension and catches:

- Type errors and inference failures
- Unused imports and variables
- Missing required overrides
- Null safety violations
- Lint rule violations from `analysis_options.yaml`

### The write-analyze-fix loop

An agent writing Dart code should follow this cycle:

```
1. Write code to disk
2. Run `dart analyze`
3. If issues found → read diagnostics, fix the code, goto 2
4. Run `dart format` (idiomatic formatting)
5. Run `dart test`
6. If failures → read output, fix, goto 2
```

This is exactly what Envoy's `RunDartTool` and dynamic tool registration
already do — `RegisterToolTool` runs `dart analyze` on generated code and
blocks registration if errors are found (warnings pass). Extend this pattern
to any code-writing workflow.

### Companion tools

| Tool              | Purpose                                    |
|-------------------|--------------------------------------------|
| `dart analyze`    | Catch type/lint/null-safety errors          |
| `dart format`     | Enforce idiomatic Dart formatting           |
| `dart fix --apply`| Auto-apply suggested fixes (deprecated APIs, preferred syntax) |
| `dart test`       | Catch logical/behavioral errors             |

All four are safe, read-only-ish (format and fix modify files but
deterministically), and fast to run.

### Strict analysis options

The stricter the `analysis_options.yaml`, the more the analyzer catches. At
minimum, enable strict mode:

```yaml
analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true

linter:
  rules:
    - include: package:lints/recommended.yaml
    # Add project-specific rules as needed
```

With strict mode, the analyzer rejects implicit `dynamic`, unchecked casts, and
raw generic types — the categories of errors that LLMs are most prone to
introducing.

## 2. Framework Knowledge via Guide Documents

The analyzer catches syntax and type errors. It does not catch:

- Using the wrong pattern for your framework
- Missing required annotations (e.g., Chary on public fields)
- Architectural mistakes (e.g., reading `.value` during component init in
  Trellis)
- Incorrect API usage that happens to be type-safe

This is where **guide documents** matter. The documentation standard used across
this workspace (see `docs/documentation-standard.md`) defines three documents
per package:

| Document         | Audience              | Purpose                            |
|------------------|-----------------------|------------------------------------|
| `README.md`      | Humans                | What, why, quick start             |
| `CLAUDE.md`      | AI modifying the pkg  | Internals, architecture, commands  |
| `docs/guide.md`  | AI using the pkg      | Complete self-contained API ref    |

The key document for agents is **`docs/guide.md`** — designed so a consumer AI
can load one file and write correct code against the package without ever
reading source. When an Envoy agent is tasked with writing code that uses Swoop,
Beaver, Chary, etc., inject the relevant guide into context (system prompt or
first message).

### What makes a good guide for agents

- **Self-contained**: every type, method signature, and constructor the agent
  needs, in one file
- **Pattern-oriented**: show the correct way to do things, not just the API
  surface
- **Pitfall-aware**: call out common mistakes and how to avoid them
- **Example-rich**: concrete usage examples the agent can pattern-match against

## 3. Custom Lint Rules

For project-specific invariants the standard analyzer can't enforce, consider
the `custom_lint` package. Examples:

- "Never read `.value` during Trellis component init"
- "All Swoop handler functions must return a `Response` subtype"
- "Chary-annotated classes must not have public fields without `@CharyField`"

Custom lint rules turn tribal knowledge into automated enforcement — an agent
doesn't need to "know" the rule if the analyzer will flag violations.

## 4. Envoy-Specific Recommendations

### For dynamic tool registration

Envoy's `RegisterToolTool` already runs `dart analyze` before accepting
generated code. This is the right pattern. Consider extending it:

- Run `dart format --output=show` to verify formatting (or auto-format)
- If tests exist in the workspace, run them after registration

### For seed tool design

When building Envoy tools that write code:

- Expose `dart analyze` as a standalone tool (`ToolPermission.compute`) so the
  agent can self-check code before attempting to use it
- Expose `dart format` similarly — cheap, safe, high value
- Include relevant guide.md content in the agent's system prompt when the task
  involves a specific package

### For system prompts

A code-writing agent's system prompt should include:

- The target Dart SDK version and language features available
- Which packages are available (and their versions)
- Pointers to run analysis: "After writing code, always run `dart analyze` and
  fix any issues before proceeding"
- Framework-specific constraints from guide documents

## Summary

| IDE Feature                  | Agent Equivalent                     |
|------------------------------|--------------------------------------|
| Real-time analyzer           | `dart analyze` after each write      |
| Auto-format on save          | `dart format`                        |
| Quick fixes                  | `dart fix --apply`                   |
| Reading existing code        | `docs/guide.md` in context           |
| IDE-specific lint warnings   | `custom_lint` rules                  |
| Running tests                | `dart test` in the loop              |

The combination of `dart analyze` (catches what the IDE catches) and guide
documents (catches what the analyzer can't) covers the vast majority of what
makes IDE-assisted code generation clean.
