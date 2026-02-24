import 'dart:convert';
import 'dart:math' as math;

import '../llm_callback.dart';
import '../memory_component.dart';
import '../memory_store.dart';
import '../models/episode.dart';
import '../stored_memory.dart';
import 'task_memory_config.dart';

const _systemPrompt = '''
You are extracting task context from an agent's recent experience.
Focus on what the user is trying to accomplish RIGHT NOW. Extract
transient, session-scoped information — not long-term preferences.

Output a JSON object with this exact structure (no other text):

{
  "items": [
    {
      "content": "A standalone statement of current task context",
      "category": "goal|decision|result|context",
      "importance": 0.7,
      "action": "new|merge"
    }
  ]
}

Category definitions:
- "goal": What the user is trying to accomplish (objectives, requirements, criteria)
- "decision": A choice made during the task (approach selected, parameter chosen)
- "result": An outcome from a tool call, computation, or action
- "context": Background information relevant to the current task

Rules:
- Be aggressive. Capture everything relevant to the current task.
- Each item should be a standalone statement — understandable without context.
- Importance reflects task relevance: goals 0.8-0.9, decisions 0.7-0.8, results 0.5-0.7, context 0.4-0.6.
- Set "action" to "merge" if this refines or updates something likely already captured.
  Set to "new" for genuinely new information.
- If nothing task-relevant is worth extracting, return: {"items": []}
''';

/// Task memory component: session-scoped, fast-decaying task context.
///
/// Writes to the shared [MemoryStore] with `component: 'task'`. Recall
/// is handled by the engine's unified recall pipeline.
class TaskMemory implements MemoryComponent {
  @override
  final String name;

  final MemoryStore _store;
  final TaskMemoryConfig _config;
  String? _currentSessionId;

  TaskMemory({
    this.name = 'task',
    required MemoryStore store,
    TaskMemoryConfig? config,
  })  : _store = store,
        _config = config ?? const TaskMemoryConfig();

  /// Visible for testing — the currently tracked session ID.
  String? get currentSessionId => _currentSessionId;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> close() async {}

  // ── Consolidation ───────────────────────────────────────────────────────

  @override
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
  ) async {
    if (episodes.isEmpty) {
      return ConsolidationReport(componentName: name);
    }

    // Session boundary detection: expire items from previous sessions.
    var itemsDecayed = 0;
    final sessionIds = episodes.map((e) => e.sessionId).toSet();
    for (final sid in sessionIds) {
      if (_currentSessionId != null && sid != _currentSessionId) {
        itemsDecayed +=
            await _store.expireSession(_currentSessionId!, name);
      }
    }
    _currentSessionId = episodes.last.sessionId;

    // Build episode transcript.
    final buffer = StringBuffer();
    for (final ep in episodes) {
      buffer.writeln('[${ep.type.name}] ${ep.content}');
    }

    // Call LLM for extraction.
    Map<String, dynamic> extraction;
    try {
      final response = await llm(_systemPrompt, buffer.toString());
      extraction = _parseJson(response);
    } catch (_) {
      return ConsolidationReport(
        componentName: name,
        itemsDecayed: itemsDecayed,
      );
    }

    var created = 0;
    var merged = 0;
    final episodeIds = episodes.map((e) => e.id).toList();

    final items = extraction['items'] as List<dynamic>? ?? [];
    for (final rawItem in items) {
      final itemMap = rawItem as Map<String, dynamic>;
      final content = itemMap['content'] as String;
      final categoryName = itemMap['category'] as String? ?? 'context';
      final importance = (itemMap['importance'] as num?)?.toDouble() ??
          _config.defaultImportance;
      final action = itemMap['action'] as String? ?? 'new';

      // Merge action: find existing similar item in the same category.
      if (action == 'merge') {
        final similar = await _store.findSimilar(
          content,
          name,
          category: categoryName,
          sessionId: _currentSessionId,
        );
        if (similar.isNotEmpty) {
          final target = similar.first;
          await _store.update(
            target.id,
            content: content,
            importance: math.max(target.importance, importance),
            sourceEpisodeIds:
                {...target.sourceEpisodeIds, ...episodeIds}.toList(),
          );
          merged++;
          continue;
        }
        // No match — fall through to create new.
      }

      // Enforce maxItemsPerSession.
      final activeCount = await _store.activeItemCount(
        name,
        sessionId: _currentSessionId,
      );
      if (activeCount >= _config.maxItemsPerSession) {
        final activeItems = await _store.activeItemsForSession(
          _currentSessionId!,
          name,
        );
        if (activeItems.isNotEmpty) {
          final sorted = activeItems.toList()
            ..sort((a, b) => a.importance.compareTo(b.importance));
          await _store.expireItem(sorted.first.id);
          itemsDecayed++;
        }
      }

      await _store.insert(StoredMemory(
        content: content,
        component: name,
        category: categoryName,
        importance: importance,
        sessionId: _currentSessionId,
        sourceEpisodeIds: episodeIds,
      ));
      created++;
    }

    return ConsolidationReport(
      componentName: name,
      itemsCreated: created,
      itemsMerged: merged,
      itemsDecayed: itemsDecayed,
      episodesConsumed: episodes.length,
    );
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  /// Parses JSON from LLM response, handling markdown code fences.
  static Map<String, dynamic> _parseJson(String response) {
    var text = response.trim();

    if (text.startsWith('```')) {
      final firstNewline = text.indexOf('\n');
      if (firstNewline != -1) {
        text = text.substring(firstNewline + 1);
      }
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
      text = text.trim();
    }

    return jsonDecode(text) as Map<String, dynamic>;
  }
}
