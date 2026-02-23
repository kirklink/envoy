import 'run_result.dart';

/// Events emitted during an [EnvoyAgent.run] call.
///
/// Listen via `agent.events` to observe agent activity in real time.
/// Each subtype has a [type] discriminator for serialization (e.g. SSE
/// event names) and a [toJson] method for wire encoding.
sealed class AgentEvent {
  /// UTC timestamp recorded when this event was created.
  final DateTime timestamp;

  /// Creates an event with the current UTC time as its [timestamp].
  AgentEvent() : timestamp = DateTime.now().toUtc();

  /// Discriminator string used as the SSE event name.
  String get type;

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson();
}

/// Emitted when [EnvoyAgent.run] begins processing a task.
class AgentStarted extends AgentEvent {
  /// The task string passed to [EnvoyAgent.run].
  final String task;

  /// Creates an event indicating a new agent run has started with [task].
  AgentStarted(this.task);

  @override
  String get type => 'agent_started';

  @override
  Map<String, dynamic> toJson() => {
        'task': task,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted before a tool's [execute] method is called.
class AgentToolCallStarted extends AgentEvent {
  /// The [Tool.name] of the tool being invoked.
  final String toolName;

  /// The input map the LLM supplied for this tool call.
  final Map<String, dynamic> input;

  /// The agent's reasoning text from the LLM response, if present.
  final String? reasoning;

  /// Creates an event indicating that a tool call is about to execute.
  AgentToolCallStarted(this.toolName, this.input, {this.reasoning});

  @override
  String get type => 'agent_tool_call_started';

  @override
  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        'input': input,
        if (reasoning != null) 'reasoning': reasoning,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted after a tool's [execute] method returns (or validation fails).
class AgentToolCallCompleted extends AgentEvent {
  /// The [Tool.name] of the tool that was invoked.
  final String toolName;

  /// Whether the tool execution succeeded.
  final bool success;

  /// The tool output (on success) or error message (on failure).
  final String output;

  /// Wall-clock time the tool execution took.
  final Duration duration;

  /// Creates an event indicating that a tool call has finished executing.
  AgentToolCallCompleted(
    this.toolName, {
    required this.success,
    required this.output,
    required this.duration,
  });

  @override
  String get type => 'agent_tool_call_completed';

  @override
  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        'success': success,
        'output': output,
        'durationMs': duration.inMilliseconds,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when a message is added to the conversation context.
class AgentMessageAdded extends AgentEvent {
  /// The message role (e.g. 'user', 'assistant').
  final String role;

  /// A truncated preview of the message content.
  final String preview;

  /// Creates an event indicating a message was added to the conversation.
  AgentMessageAdded(this.role, this.preview);

  @override
  String get type => 'agent_message_added';

  @override
  Map<String, dynamic> toJson() => {
        'role': role,
        'preview': preview,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when [EnvoyAgent.run] finishes (success, max iterations, or error).
class AgentCompleted extends AgentEvent {
  /// The final text response from the agent, or empty on non-completed outcomes.
  final String response;

  /// How the run concluded (completed, max iterations, or error).
  final RunOutcome outcome;

  /// Number of LLM iterations used during this run.
  final int iterations;

  /// Wall-clock time for the entire run.
  final Duration duration;

  /// Token usage aggregated across all LLM calls in this run.
  final TokenUsage tokenUsage;

  /// Total number of tool invocations during this run.
  final int toolCallCount;

  /// Human-readable error message when [outcome] is [RunOutcome.error].
  final String? errorMessage;

  /// Creates an event indicating that the agent run has finished.
  AgentCompleted({
    required this.response,
    required this.outcome,
    required this.iterations,
    required this.duration,
    required this.tokenUsage,
    required this.toolCallCount,
    this.errorMessage,
  });

  @override
  String get type => 'agent_completed';

  @override
  Map<String, dynamic> toJson() => {
        'response': response,
        'outcome': outcome.name,
        'iterations': iterations,
        'durationMs': duration.inMilliseconds,
        'tokenUsage': {
          'input': tokenUsage.inputTokens,
          'output': tokenUsage.outputTokens,
          'total': tokenUsage.totalTokens,
        },
        'toolCallCount': toolCallCount,
        if (errorMessage != null) 'errorMessage': errorMessage,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted on non-retryable API errors during the agent loop.
class AgentError extends AgentEvent {
  /// Human-readable description of the error that occurred.
  final String message;

  /// Creates an event indicating a non-retryable API error.
  AgentError(this.message);

  @override
  String get type => 'agent_error';

  @override
  Map<String, dynamic> toJson() => {
        'message': message,
        'timestamp': timestamp.toIso8601String(),
      };
}
