/// How the agent run concluded.
enum RunOutcome {
  /// The agent produced a text response.
  completed,

  /// The agent exhausted [EnvoyConfig.maxIterations] without completing.
  maxIterations,

  /// The run was aborted due to an API error (rate limit, server error, etc.).
  error,
}

/// Aggregated token counts across all LLM calls in a run.
class TokenUsage {
  final int inputTokens;
  final int outputTokens;
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;

  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.cacheReadInputTokens = 0,
  });

  static const zero = TokenUsage();

  int get totalTokens => inputTokens + outputTokens;

  TokenUsage operator +(TokenUsage other) => TokenUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cacheCreationInputTokens:
            cacheCreationInputTokens + other.cacheCreationInputTokens,
        cacheReadInputTokens:
            cacheReadInputTokens + other.cacheReadInputTokens,
      );

  @override
  String toString() =>
      'TokenUsage(in: $inputTokens, out: $outputTokens, total: $totalTokens)';
}

/// A single tool invocation recorded during the run.
class ToolCallRecord {
  final String name;
  final Map<String, dynamic> input;
  final bool success;

  /// The tool output (on success) or error message (on failure).
  final String output;
  final Duration duration;

  /// The agent's reasoning text from the LLM response that triggered this
  /// tool call. Only present on the first tool call of each iteration —
  /// subsequent parallel tool calls in the same response have `null`.
  final String? reasoning;

  const ToolCallRecord({
    required this.name,
    required this.input,
    required this.success,
    required this.output,
    required this.duration,
    this.reasoning,
  });

  @override
  String toString() {
    final status = success ? 'ok' : 'err';
    final r = reasoning != null ? ', ${reasoning!.length}ch reasoning' : '';
    return 'ToolCallRecord($name, $status, ${duration.inMilliseconds}ms$r)';
  }
}

/// Structured result from [EnvoyAgent.run].
///
/// Contains the response text plus execution metadata: iterations used,
/// tool calls with outcomes, token usage, and wall-clock duration.
class RunResult {
  /// The final text response from the agent.
  ///
  /// Empty string when [outcome] is [RunOutcome.maxIterations].
  final String response;

  final RunOutcome outcome;

  /// Number of LLM iterations used (each iteration is one API call).
  final int iterations;

  /// Wall-clock time for the entire run.
  final Duration duration;

  /// Token usage aggregated across all LLM calls in this run.
  final TokenUsage tokenUsage;

  /// Ordered log of every tool invocation during this run.
  final List<ToolCallRecord> toolCalls;

  /// Human-readable error message when [outcome] is [RunOutcome.error].
  final String? errorMessage;

  const RunResult({
    required this.response,
    required this.outcome,
    required this.iterations,
    required this.duration,
    required this.tokenUsage,
    required this.toolCalls,
    this.errorMessage,
  });

  @override
  String toString() {
    final base = 'RunResult($outcome, ${iterations}i, '
        '${toolCalls.length} tools, $tokenUsage, '
        '${duration.inMilliseconds}ms)';
    if (errorMessage != null) return '$base — $errorMessage';
    return base;
  }
}
