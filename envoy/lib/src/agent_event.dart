import 'run_result.dart';

/// Events emitted during an [EnvoyAgent.run] call.
///
/// Listen via `agent.events` to observe agent activity in real time.
/// Each subtype has a [type] discriminator for serialization (e.g. SSE
/// event names) and a [toJson] method for wire encoding.
sealed class AgentEvent {
  final DateTime timestamp;
  AgentEvent() : timestamp = DateTime.now().toUtc();

  /// Discriminator string used as the SSE event name.
  String get type;

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson();
}

/// Emitted when [EnvoyAgent.run] begins processing a task.
class AgentStarted extends AgentEvent {
  final String task;
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
  final String toolName;
  final Map<String, dynamic> input;
  final String? reasoning;
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
  final String toolName;
  final bool success;
  final String output;
  final Duration duration;
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
  final String role;
  final String preview;
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
  final String response;
  final RunOutcome outcome;
  final int iterations;
  final Duration duration;
  final TokenUsage tokenUsage;
  final int toolCallCount;
  final String? errorMessage;
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
  final String message;
  AgentError(this.message);

  @override
  String get type => 'agent_error';

  @override
  Map<String, dynamic> toJson() => {
        'message': message,
        'timestamp': timestamp.toIso8601String(),
      };
}
