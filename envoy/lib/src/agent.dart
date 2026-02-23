import 'dart:async';
import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

import 'agent_event.dart';
import 'context.dart';
import 'memory.dart';
import 'run_result.dart';
import 'tool.dart';

/// Thrown when the agent cannot complete a task within [EnvoyConfig.maxIterations].
class EnvoyException implements Exception {
  /// Human-readable description of the exception.
  final String message;

  /// Creates an [EnvoyException] with the given [message].
  const EnvoyException(this.message);

  @override
  String toString() => 'EnvoyException: $message';
}

/// Configuration for an [EnvoyAgent] instance.
class EnvoyConfig {
  /// Anthropic API key used for authentication.
  final String apiKey;

  /// Anthropic model ID to use.
  final String model;

  /// Token budget passed to the API and used for context pruning.
  final int maxTokens;

  /// Maximum LLM iterations per [EnvoyAgent.run] call before giving up.
  final int maxIterations;

  /// Creates an agent configuration with the given [apiKey] and optional overrides.
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
  /// The configuration controlling model, token budget, and iteration limit.
  final EnvoyConfig config;
  final anthropic.AnthropicClient _client;
  final EnvoyContext _context;
  final Map<String, Tool> _tools;

  /// Optional observer called after every tool execution.
  ///
  /// Useful for logging, progress indicators, or debugging. The callback
  /// receives the tool name, the input the model supplied, and the result.
  final OnToolCall? onToolCall;
  final AgentMemory? _memory;
  final String _systemPrompt;

  final StreamController<AgentEvent> _eventController =
      StreamController<AgentEvent>.broadcast();

  /// Stream of events emitted during agent runs.
  ///
  /// This is a broadcast stream — multiple listeners can subscribe.
  /// Events are emitted for: task start, tool call start/complete,
  /// message additions, and run completion/error.
  Stream<AgentEvent> get events => _eventController.stream;

  void _emit(AgentEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  static String _preview(String s, [int max = 200]) =>
      s.length > max ? '${s.substring(0, max)}...' : s;

  /// Creates an agent with the given [config], optional [tools], and callbacks.
  ///
  /// If [context] is omitted a fresh [EnvoyContext] is created. If [memory]
  /// is provided, [reflect] can persist self-knowledge after a run.
  EnvoyAgent(
    this.config, {
    List<Tool> tools = const [],
    EnvoyContext? context,
    this.onToolCall,
    AgentMemory? memory,
    String? systemPrompt,
  })  : _client = anthropic.AnthropicClient(apiKey: config.apiKey),
        _context = context ?? EnvoyContext(maxTokens: config.maxTokens),
        _tools = {for (final t in tools) t.name: t},
        _memory = memory,
        _systemPrompt = systemPrompt ?? _defaultSystemPrompt;

  /// Registers or replaces a tool at runtime.
  ///
  /// Allows tools to be added after construction — the agent loop reads the
  /// tool map fresh on every iteration, so newly registered tools are
  /// immediately available to the LLM on the next call.
  ///
  /// Pass this method as the `onRegister` callback to [RegisterToolTool].
  void registerTool(Tool tool) => _tools[tool.name] = tool;

  /// Returns `true` if a tool with [name] is currently registered.
  ///
  /// Pass this as the `toolExists` callback to [RegisterToolTool] to prevent
  /// the agent from re-registering tools that are already available.
  bool hasTool(String name) => _tools.containsKey(name);

  /// Returns the registered tool with [name], or `null` if not found.
  Tool? getTool(String name) => _tools[name];

  /// Maximum retries for transient API errors (rate limit, overloaded).
  static const _maxRetries = 3;

  /// Executes [task], running the agent loop until a text response is produced
  /// or [EnvoyConfig.maxIterations] is reached.
  ///
  /// Returns a [RunResult] containing the response text plus execution
  /// metadata: iterations used, tool calls, token usage, and duration.
  /// Check [RunResult.outcome] to distinguish success from exhaustion.
  Future<RunResult> run(String task) async {
    _context.addUser(task);
    _emit(AgentStarted(task));
    _emit(AgentMessageAdded('user', _preview(task)));

    final stopwatch = Stopwatch()..start();
    var tokens = TokenUsage.zero;
    final toolCallLog = <ToolCallRecord>[];
    var iterationsUsed = 0;

    for (var i = 0; i < config.maxIterations; i++) {
      iterationsUsed = i + 1;

      final anthropic.Message response;
      try {
        response = await _llmCallWithRetry();
      } on anthropic.AnthropicClientException catch (e) {
        // Non-retryable API error, or retries exhausted.
        stopwatch.stop();
        final errorMsg = 'API error ${e.code}: ${e.message}';
        _emit(AgentError(errorMsg));
        _emit(AgentCompleted(
          response: '',
          outcome: RunOutcome.error,
          iterations: iterationsUsed,
          duration: stopwatch.elapsed,
          tokenUsage: tokens,
          toolCallCount: toolCallLog.length,
          errorMessage: errorMsg,
        ));
        return RunResult(
          response: '',
          outcome: RunOutcome.error,
          iterations: iterationsUsed,
          duration: stopwatch.elapsed,
          tokenUsage: tokens,
          toolCalls: toolCallLog,
          errorMessage: errorMsg,
        );
      }
      tokens = tokens + _extractUsage(response);

      final toolUses = response.content.blocks
          .map((b) => b.toolUse)
          .nonNulls
          .toList();

      if (toolUses.isEmpty) {
        // Model returned a text response — we are done.
        _context.addAssistant(response.content);
        stopwatch.stop();
        _emit(AgentMessageAdded('assistant', _preview(response.content.text)));
        _emit(AgentCompleted(
          response: response.content.text,
          outcome: RunOutcome.completed,
          iterations: iterationsUsed,
          duration: stopwatch.elapsed,
          tokenUsage: tokens,
          toolCallCount: toolCallLog.length,
        ));
        return RunResult(
          response: response.content.text,
          outcome: RunOutcome.completed,
          iterations: iterationsUsed,
          duration: stopwatch.elapsed,
          tokenUsage: tokens,
          toolCalls: toolCallLog,
        );
      }

      // Model requested tool(s) — execute and feed results back.
      _context.addAssistant(response.content);

      // Extract the agent's reasoning (text blocks alongside tool_use blocks).
      // Attached to the first ToolCallRecord of this iteration only.
      final rawReasoning = response.content.text.trim();
      String? reasoning = rawReasoning.isEmpty ? null : rawReasoning;

      for (final toolUse in toolUses) {
        final tool = _tools[toolUse.name];
        if (tool == null) {
          _emit(AgentToolCallStarted(toolUse.name, toolUse.input,
              reasoning: reasoning));
          _emit(AgentToolCallCompleted(toolUse.name,
              success: false,
              output: 'unknown tool "${toolUse.name}"',
              duration: Duration.zero));
          toolCallLog.add(ToolCallRecord(
            name: toolUse.name,
            input: toolUse.input,
            success: false,
            output: 'unknown tool "${toolUse.name}"',
            duration: Duration.zero,
            reasoning: reasoning,
          ));
          reasoning = null; // Only attach to the first tool call.
          _context.addToolResult(
            toolUse.id,
            'Error: unknown tool "${toolUse.name}"',
            isError: true,
          );
          continue;
        }

        final validationError = await tool.validateInput(toolUse.input);
        if (validationError != null) {
          final errMsg = validationError.error ?? 'validation error';
          _emit(AgentToolCallStarted(toolUse.name, toolUse.input,
              reasoning: reasoning));
          _emit(AgentToolCallCompleted(toolUse.name,
              success: false, output: errMsg, duration: Duration.zero));
          onToolCall?.call(toolUse.name, toolUse.input, validationError);
          toolCallLog.add(ToolCallRecord(
            name: toolUse.name,
            input: toolUse.input,
            success: false,
            output: errMsg,
            duration: Duration.zero,
            reasoning: reasoning,
          ));
          reasoning = null;
          _context.addToolResult(
            toolUse.id,
            errMsg,
            isError: true,
          );
          continue;
        }

        _emit(AgentToolCallStarted(toolUse.name, toolUse.input,
            reasoning: reasoning));
        final toolStopwatch = Stopwatch()..start();
        final result = await tool.execute(toolUse.input);
        toolStopwatch.stop();

        final output =
            result.success ? result.output : (result.error ?? 'unknown error');
        _emit(AgentToolCallCompleted(toolUse.name,
            success: result.success,
            output: _preview(output, 500),
            duration: toolStopwatch.elapsed));
        onToolCall?.call(toolUse.name, toolUse.input, result);
        toolCallLog.add(ToolCallRecord(
          name: toolUse.name,
          input: toolUse.input,
          success: result.success,
          output: output,
          duration: toolStopwatch.elapsed,
          reasoning: reasoning,
        ));
        reasoning = null;
        _context.addToolResult(
          toolUse.id,
          output,
          isError: !result.success,
        );
      }
    }

    stopwatch.stop();
    _emit(AgentCompleted(
      response: '',
      outcome: RunOutcome.maxIterations,
      iterations: iterationsUsed,
      duration: stopwatch.elapsed,
      tokenUsage: tokens,
      toolCallCount: toolCallLog.length,
    ));
    return RunResult(
      response: '',
      outcome: RunOutcome.maxIterations,
      iterations: iterationsUsed,
      duration: stopwatch.elapsed,
      tokenUsage: tokens,
      toolCalls: toolCallLog,
    );
  }

  /// Extracts token usage from an LLM response.
  static TokenUsage _extractUsage(anthropic.Message response) {
    final usage = response.usage;
    if (usage == null) return TokenUsage.zero;
    return TokenUsage(
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheCreationInputTokens: usage.cacheCreationInputTokens ?? 0,
      cacheReadInputTokens: usage.cacheReadInputTokens ?? 0,
    );
  }

  /// Runs a post-task reflection pass, storing self-knowledge for future sessions.
  ///
  /// Makes a single LLM call over the current session history and asks the agent
  /// what — if anything — is worth remembering about itself. Entries are written
  /// to [AgentMemory] with agent-chosen type labels (no prescribed taxonomy).
  ///
  /// Call this after [run] completes. It does not modify the session context.
  /// A no-op if no [AgentMemory] was provided at construction, or if the
  /// session has no messages yet.
  Future<void> reflect() async {
    if (_memory == null || _context.messages.isEmpty) return;

    final reflectMessages = [
      ..._context.messages,
      anthropic.Message(
        role: anthropic.MessageRole.user,
        content: anthropic.MessageContent.text(_reflectPrompt),
      ),
    ];

    final anthropic.Message response;
    try {
      response = await _client.createMessage(
        request: anthropic.CreateMessageRequest(
          model: anthropic.Model.modelId(config.model),
          maxTokens: 1024,
          system: anthropic.CreateMessageRequestSystem.text(_systemPrompt),
          messages: reflectMessages,
        ),
      );
    } on anthropic.AnthropicClientException {
      // Reflection is best-effort — silently skip on API errors.
      return;
    }

    final text = response.content.text.trim();
    if (text.isEmpty || text == '[]') return;

    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final type = item['type'] as String?;
        final content = item['content'] as String?;
        if (type != null && type.isNotEmpty && content != null && content.isNotEmpty) {
          await _memory!.remember(MemoryEntry(
            type: type,
            content: content,
            createdAt: DateTime.now().toUtc(),
          ));
        }
      }
    } on FormatException {
      // Agent returned non-JSON — store as a raw reflection entry.
      await _memory!.remember(MemoryEntry(
        type: 'reflection',
        content: text,
        createdAt: DateTime.now().toUtc(),
      ));
    }
  }

  static const _defaultSystemPrompt =
      'You are Envoy, an autonomous agent that solves problems by using and '
      'building tools.\n\n'
      'If no existing tool covers what you need, you can write and register new '
      'ones (search first to avoid duplicates).\n\n'
      'When you need clarification, lack information, or are stuck after trying '
      'multiple approaches, ask the user for help rather than guessing or '
      'repeating failed attempts.\n\n'
      'Think step by step. When a tool call fails, analyze the error before '
      'retrying with the same approach.\n\n'
      'When fetching URLs:\n'
      '- Prefer JSON API endpoints over HTML pages.\n'
      '- Use query parameters to filter and limit results '
      '(e.g., ?limit=1 to explore an API structure before fetching more).\n'
      '- Large responses will be truncated. If you see a truncation notice, '
      'try a more targeted request.';

  static const _reflectPrompt =
      'Review what happened in this session. As an agent, what — if anything — '
      'do you want to remember about yourself for future sessions?\n\n'
      'Write 0–3 memory entries about what you learned, what worked, what failed, '
      'what you\'re curious about, or anything about your own nature worth preserving.\n\n'
      'Respond with ONLY a JSON array (no other text):\n'
      '[\n'
      '  {"type": "your_label", "content": "the memory in your own words"}\n'
      ']\n\n'
      'Use whatever type labels feel right (e.g. success, failure, curiosity, '
      'strategy, character). If nothing is worth keeping, return: []';

  /// Whether [code] is a transient HTTP error worth retrying.
  static bool _isRetryable(int? code) => code == 429 || code == 529;

  /// Calls the LLM with automatic retry + exponential backoff for transient
  /// errors (429 rate limit, 529 overloaded).
  ///
  /// Throws [anthropic.AnthropicClientException] if the error is
  /// non-retryable or all retry attempts are exhausted.
  Future<anthropic.Message> _llmCallWithRetry() async {
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await _client.createMessage(
          request: anthropic.CreateMessageRequest(
            model: anthropic.Model.modelId(config.model),
            maxTokens: config.maxTokens,
            system: anthropic.CreateMessageRequestSystem.text(_systemPrompt),
            tools: _toolSchemas(),
            messages: _context.messages,
          ),
        );
      } on anthropic.AnthropicClientException catch (e) {
        if (!_isRetryable(e.code) || attempt == _maxRetries) rethrow;
        // Exponential backoff: 2s, 4s, 8s.
        final delay = Duration(seconds: 2 << attempt);
        await Future<void>.delayed(delay);
      }
    }
    // Unreachable — the loop either returns or rethrows.
    throw StateError('unreachable');
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
