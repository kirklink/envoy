import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

/// Called whenever a message is appended to the context.
///
/// Use this to persist messages as they arrive — write each message to
/// [StanzaEnvoyStorage] so the session survives across [EnvoyAgent.run] calls.
/// The callback fires after the message is added but before pruning.
typedef OnMessage = void Function(anthropic.Message message);

/// Manages conversation history for a single Envoy session.
///
/// Stores messages as [anthropic.Message] objects ready for the API.
/// Prunes oldest exchanges when the estimated token count approaches [maxTokens].
class EnvoyContext {
  /// Rough token budget. Pruning triggers at 80% of this value.
  final int maxTokens;

  /// Optional callback fired after each message is appended.
  ///
  /// Use for persistence: write each incoming message to storage so
  /// the session can be restored across process restarts.
  final OnMessage? onMessage;

  final List<anthropic.Message> _messages = [];

  /// Creates a context, optionally pre-seeded with [messages].
  ///
  /// Pass [messages] to restore a previously persisted session — load them
  /// from storage and hand them in here before the first [EnvoyAgent.run] call.
  EnvoyContext({
    this.maxTokens = 8192,
    this.onMessage,
    List<anthropic.Message>? messages,
  }) {
    if (messages != null) _messages.addAll(messages);
  }

  /// All messages in chronological order.
  List<anthropic.Message> get messages => List.unmodifiable(_messages);

  /// Number of messages currently in context.
  int get length => _messages.length;

  /// Appends a user text message.
  void addUser(String text) {
    final msg = anthropic.Message(
      role: anthropic.MessageRole.user,
      content: anthropic.MessageContent.text(text),
    );
    _messages.add(msg);
    onMessage?.call(msg);
    _maybePrune();
  }

  /// Appends an assistant response (text or tool use blocks).
  void addAssistant(anthropic.MessageContent content) {
    final msg = anthropic.Message(
      role: anthropic.MessageRole.assistant,
      content: content,
    );
    _messages.add(msg);
    onMessage?.call(msg);
  }

  /// Appends a tool result as a user message, as required by the Anthropic API.
  void addToolResult(String toolUseId, String output, {bool isError = false}) {
    final msg = anthropic.Message(
      role: anthropic.MessageRole.user,
      content: anthropic.MessageContent.blocks([
        anthropic.Block.toolResult(
          toolUseId: toolUseId,
          content: anthropic.ToolResultBlockContent.text(output),
          isError: isError ? true : null,
        ),
      ]),
    );
    _messages.add(msg);
    onMessage?.call(msg);
  }

  /// Estimated token count using a 4-chars-per-token approximation.
  int get estimatedTokens {
    var chars = 0;
    for (final msg in _messages) {
      chars += msg.content.text.length;
    }
    return chars ~/ 4;
  }

  /// Removes the oldest user/assistant exchange when approaching token budget.
  ///
  /// Never prunes below 2 messages. Does not split tool use / tool result pairs
  /// — always removes at least 2 messages at a time to preserve message order.
  void _maybePrune() {
    final threshold = (maxTokens * 0.8).toInt();
    while (estimatedTokens > threshold && _messages.length > 2) {
      // Remove the oldest pair of messages.
      _messages.removeAt(0);
      if (_messages.isNotEmpty) _messages.removeAt(0);
    }
  }
}
