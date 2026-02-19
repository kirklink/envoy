/// A single memory entry written by the agent about itself.
///
/// Entries are produced by [EnvoyAgent.reflect] after a session completes.
/// The [type] is a free-form label chosen by the agent — no prescribed taxonomy.
class MemoryEntry {
  /// Agent-chosen category label (e.g. 'success', 'failure', 'curiosity').
  final String type;

  /// The memory content, written in the agent's own voice.
  final String content;

  final DateTime createdAt;

  const MemoryEntry({
    required this.type,
    required this.content,
    required this.createdAt,
  });
}

/// Interface for agent self-memory storage.
///
/// Implemented by storage backends (e.g. [StanzaMemoryStorage]).
/// Passed to [EnvoyAgent] at construction; used by [EnvoyAgent.reflect].
///
/// This is not a tool — the agent does not call these methods during task
/// execution. Memory consolidation is a post-task framework concern.
abstract class AgentMemory {
  /// Creates the backing store if it does not already exist.
  ///
  /// Safe to call on every startup (idempotent).
  Future<void> initialize();

  /// Persists a single memory entry.
  Future<void> remember(MemoryEntry entry);

  /// Returns stored entries, optionally filtered by [type] or [query] (FTS).
  ///
  /// If both are provided, both filters apply. If neither is provided,
  /// returns all entries ordered by recency.
  Future<List<MemoryEntry>> recall({String? type, String? query});
}
