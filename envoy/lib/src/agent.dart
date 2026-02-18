import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

import 'context.dart';
import 'tool.dart';

/// Thrown when the agent cannot complete a task within [EnvoyConfig.maxIterations].
class EnvoyException implements Exception {
  final String message;
  const EnvoyException(this.message);

  @override
  String toString() => 'EnvoyException: $message';
}

/// Configuration for an [EnvoyAgent] instance.
class EnvoyConfig {
  final String apiKey;

  /// Anthropic model ID to use.
  final String model;

  /// Token budget passed to the API and used for context pruning.
  final int maxTokens;

  /// Maximum LLM iterations per [EnvoyAgent.run] call before giving up.
  final int maxIterations;

  const EnvoyConfig({
    required this.apiKey,
    this.model = 'claude-opus-4-6',
    this.maxTokens = 8192,
    this.maxIterations = 20,
  });
}

/// Signature for the tool-call observer callback.
///
/// Called after each tool execution with the tool [name], the [input] map
/// the model supplied, and the [result] returned by the tool.
typedef OnToolCall = void Function(
  String name,
  Map<String, dynamic> input,
  ToolResult result,
);

/// The core Envoy agent.
///
/// Runs the LLM ↔ tool loop until the model returns a plain text response
/// or [EnvoyConfig.maxIterations] is reached.
///
/// Phase 1: in-memory only, no persistence, streaming deferred to Phase 2.
class EnvoyAgent {
  final EnvoyConfig config;
  final anthropic.AnthropicClient _client;
  final EnvoyContext _context;
  final Map<String, Tool> _tools;

  /// Optional observer called after every tool execution.
  ///
  /// Useful for logging, progress indicators, or debugging. The callback
  /// receives the tool name, the input the model supplied, and the result.
  final OnToolCall? onToolCall;

  EnvoyAgent(
    this.config, {
    List<Tool> tools = const [],
    EnvoyContext? context,
    this.onToolCall,
  })  : _client = anthropic.AnthropicClient(apiKey: config.apiKey),
        _context = context ?? EnvoyContext(maxTokens: config.maxTokens),
        _tools = {for (final t in tools) t.name: t};

  /// Executes [task], running the agent loop until a text response is produced.
  ///
  /// Returns the final text response from the model.
  /// Throws [EnvoyException] if [EnvoyConfig.maxIterations] is exceeded.
  Future<String> run(String task) async {
    _context.addUser(task);

    for (var i = 0; i < config.maxIterations; i++) {
      final response = await _llmCall();
      final toolUses = response.content.blocks
          .map((b) => b.toolUse)
          .nonNulls
          .toList();

      if (toolUses.isEmpty) {
        // Model returned a text response — we are done.
        _context.addAssistant(response.content);
        return response.content.text;
      }

      // Model requested tool(s) — execute and feed results back.
      _context.addAssistant(response.content);

      for (final toolUse in toolUses) {
        final tool = _tools[toolUse.name];
        if (tool == null) {
          _context.addToolResult(
            toolUse.id,
            'Error: unknown tool "${toolUse.name}"',
            isError: true,
          );
          continue;
        }

        final result = await tool.execute(toolUse.input);
        onToolCall?.call(toolUse.name, toolUse.input, result);
        _context.addToolResult(
          toolUse.id,
          result.success ? result.output : (result.error ?? 'unknown error'),
          isError: !result.success,
        );
      }
    }

    throw EnvoyException(
      'task did not complete within ${config.maxIterations} iterations',
    );
  }

  Future<anthropic.Message> _llmCall() {
    return _client.createMessage(
      request: anthropic.CreateMessageRequest(
        model: anthropic.Model.modelId(config.model),
        maxTokens: config.maxTokens,
        tools: _toolSchemas(),
        messages: _context.messages,
      ),
    );
  }

  List<anthropic.Tool> _toolSchemas() {
    return _tools.values
        .map((t) => anthropic.Tool.custom(
              name: t.name,
              description: t.description,
              inputSchema: t.inputSchema,
            ))
        .toList();
  }
}
