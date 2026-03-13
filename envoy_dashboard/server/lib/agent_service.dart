import 'dart:async';

import 'package:envoy/envoy.dart';
import 'package:envoy_tools/envoy_tools.dart';

enum AgentStatus { idle, running }

/// Wraps an [EnvoyAgent], managing lifecycle and broadcasting events.
///
/// Creates a fresh agent per task. Listen on [events] for real-time
/// activity (tool calls, messages, completion).
class AgentService {
  final EnvoyConfig _config;
  final String _workspaceRoot;

  AgentStatus _status = AgentStatus.idle;
  RunResult? _lastResult;

  /// Broadcast controller — multiple SSE clients can listen independently.
  final StreamController<AgentEvent> _eventBroadcast =
      StreamController<AgentEvent>.broadcast();

  AgentService({
    required EnvoyConfig config,
    required String workspaceRoot,
  })  : _config = config,
        _workspaceRoot = workspaceRoot;

  AgentStatus get status => _status;
  RunResult? get lastResult => _lastResult;
  Stream<AgentEvent> get events => _eventBroadcast.stream;

  /// Starts a task. Completes when the agent finishes.
  ///
  /// Listen on [events] for progress. Throws [StateError] if already running.
  Future<void> runTask(String task, {String? model}) async {
    if (_status == AgentStatus.running) {
      throw StateError('Agent is already running a task.');
    }

    _status = AgentStatus.running;

    final effectiveConfig = model != null
        ? EnvoyConfig(
            apiKey: _config.apiKey,
            model: model,
            maxTokens: _config.maxTokens,
            maxIterations: _config.maxIterations,
          )
        : _config;

    final agent = EnvoyAgent(
      effectiveConfig,
      tools: EnvoyTools.defaults(_workspaceRoot),
    );

    // Forward agent events to our broadcast controller.
    final subscription = agent.events.listen(
      (event) => _eventBroadcast.add(event),
      onError: (Object e) => _eventBroadcast.add(AgentError(e.toString())),
    );

    try {
      _lastResult = await agent.run(task);
    } catch (e) {
      _eventBroadcast.add(AgentError(e.toString()));
    } finally {
      await subscription.cancel();
      _status = AgentStatus.idle;
    }
  }

  /// JSON-serializable status snapshot.
  Map<String, dynamic> toStatusJson() => {
        'status': _status.name,
        'lastResult': _lastResult != null
            ? {
                'outcome': _lastResult!.outcome.name,
                'iterations': _lastResult!.iterations,
                'toolCalls': _lastResult!.toolCalls.length,
                'duration': _lastResult!.duration.inMilliseconds,
                'tokenUsage': {
                  'input': _lastResult!.tokenUsage.inputTokens,
                  'output': _lastResult!.tokenUsage.outputTokens,
                  'total': _lastResult!.tokenUsage.totalTokens,
                },
              }
            : null,
      };
}
