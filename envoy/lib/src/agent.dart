import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

import 'context.dart';
import 'memory.dart';
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
  final AgentMemory? _memory;

  EnvoyAgent(
    this.config, {
    List<Tool> tools = const [],
    EnvoyContext? context,
    this.onToolCall,
    AgentMemory? memory,
  })  : _client = anthropic.AnthropicClient(apiKey: config.apiKey),
        _context = context ?? EnvoyContext(maxTokens: config.maxTokens),
        _tools = {for (final t in tools) t.name: t},
        _memory = memory;

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

        final validationError = await tool.validateInput(toolUse.input);
        if (validationError != null) {
          onToolCall?.call(toolUse.name, toolUse.input, validationError);
          _context.addToolResult(
            toolUse.id,
            validationError.error ?? 'validation error',
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

    final response = await _client.createMessage(
      request: anthropic.CreateMessageRequest(
        model: anthropic.Model.modelId(config.model),
        maxTokens: 1024,
        messages: reflectMessages,
      ),
    );

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
