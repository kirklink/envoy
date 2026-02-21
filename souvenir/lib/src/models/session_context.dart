import 'episode.dart';
import 'memory.dart';

/// Assembled context for the start of a new agent session.
///
/// Built by [Souvenir.loadContext]. Gathers relevant memories, recent
/// episodes, and (in future phases) personality, identity, and procedures.
class SessionContext {
  /// Relevant Tier 2 memories, token-budgeted.
  final List<Memory> memories;

  /// Recent Tier 1 episodes (today + yesterday).
  final List<Episode> episodes;

  /// Current personality text (Phase 5 — null for now).
  final String? personality;

  /// Core identity text (Phase 5 — null for now).
  final String? identity;

  /// Matching Tier 3 procedural docs (Phase 6 — empty for now).
  final List<String> procedures;

  const SessionContext({
    this.memories = const [],
    this.episodes = const [],
    this.personality,
    this.identity,
    this.procedures = const [],
  });

  /// Estimated token count using the chars/4 heuristic.
  int get estimatedTokens {
    var chars = 0;
    for (final m in memories) {
      chars += m.content.length;
    }
    for (final e in episodes) {
      chars += e.content.length;
    }
    if (personality != null) chars += personality!.length;
    if (identity != null) chars += identity!.length;
    for (final p in procedures) {
      chars += p.length;
    }
    return (chars / 4).ceil();
  }
}
