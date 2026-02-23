import 'dart:convert';
import 'dart:math' as math;

import '../budget.dart';
import '../labeled_recall.dart';
import '../llm_callback.dart';
import '../memory_component.dart';
import '../models/episode.dart';
import 'task_item.dart';
import 'task_memory_config.dart';
import 'task_memory_store.dart';

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
/// Implements [MemoryComponent] with:
/// - Aggressive LLM extraction (goals, decisions, results, context)
/// - Session boundary detection (expire previous session on sessionId change)
/// - Category-weighted recall with recency boost
/// - In-memory storage by default (lightweight, no disk)
class TaskMemory implements MemoryComponent {
  @override
  final String name;

  final TaskMemoryStore _store;
  final TaskMemoryConfig _config;
  String? _currentSessionId;

  TaskMemory({
    this.name = 'task',
    TaskMemoryStore? store,
    TaskMemoryConfig? config,
  })  : _store = store ?? InMemoryTaskMemoryStore(),
        _config = config ?? const TaskMemoryConfig();

  /// Visible for testing — the currently tracked session ID.
  String? get currentSessionId => _currentSessionId;

  @override
  Future<void> initialize() async {
    await _store.initialize();
  }

  @override
  Future<void> close() async {
    await _store.close();
  }

  // ── Consolidation ───────────────────────────────────────────────────────

  @override
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
    ComponentBudget budget,
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
            await _store.expireSession(_currentSessionId!, DateTime.now().toUtc());
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
      final category = TaskItemCategory.values.firstWhere(
        (c) => c.name == categoryName,
        orElse: () => TaskItemCategory.context,
      );
      final importance = (itemMap['importance'] as num?)?.toDouble() ??
          _config.defaultImportance;
      final action = itemMap['action'] as String? ?? 'new';

      // Merge action: find existing similar item in the same category.
      if (action == 'merge') {
        final similar = await _store.findSimilar(
          content,
          category,
          _currentSessionId!,
        );
        if (similar.isNotEmpty) {
          final target = similar.first;
          await _store.update(
            target.id,
            content: content,
            importance: math.max(target.importance, importance),
            sourceEpisodeIds: {...target.sourceEpisodeIds, ...episodeIds}.toList(),
          );
          merged++;
          continue;
        }
        // No match — fall through to create new.
      }

      // Enforce maxItemsPerSession.
      final activeCount = await _store.activeItemCount(_currentSessionId!);
      if (activeCount >= _config.maxItemsPerSession) {
        final activeItems =
            await _store.activeItemsForSession(_currentSessionId!);
        if (activeItems.isNotEmpty) {
          activeItems.sort((a, b) => a.importance.compareTo(b.importance));
          await _store.expireItem(activeItems.first.id, DateTime.now().toUtc());
          itemsDecayed++;
        }
      }

      await _store.insert(TaskItem(
        content: content,
        category: category,
        importance: importance,
        sessionId: _currentSessionId!,
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

  // ── Recall ──────────────────────────────────────────────────────────────

  @override
  Future<List<LabeledRecall>> recall(
    String query,
    ComponentBudget budget,
  ) async {
    if (_currentSessionId == null) return [];

    final items = await _store.activeItemsForSession(_currentSessionId!);
    if (items.isEmpty) return [];

    final queryTokens = _tokenize(query);
    final now = DateTime.now().toUtc();
    final scored = <({TaskItem item, double score})>[];

    for (final item in items) {
      final itemTokens = _tokenize(item.content);

      // Signal 1: Keyword overlap (Jaccard similarity).
      double keywordScore;
      if (queryTokens.isEmpty || itemTokens.isEmpty) {
        keywordScore = 0.05;
      } else {
        final intersection = queryTokens.intersection(itemTokens);
        final union = queryTokens.union(itemTokens);
        keywordScore = union.isEmpty ? 0.05 : intersection.length / union.length;
        // Floor so high-importance goals surface even for loosely related queries.
        if (keywordScore == 0) keywordScore = 0.05;
      }

      // Signal 2: Recency boost (exponential decay, hours-scale).
      final ageHours = now.difference(item.createdAt).inMinutes / 60.0;
      final recencyMultiplier =
          math.exp(-_config.recencyDecayLambda * math.max(0, ageHours));

      // Signal 3: Category weight.
      final categoryWeight = _config.categoryWeights[item.category] ?? 1.0;

      // Signal 4: Importance.
      final importanceMultiplier = item.importance;

      final finalScore =
          keywordScore * recencyMultiplier * categoryWeight * importanceMultiplier;

      scored.add((item: item, score: finalScore));
    }

    // Sort descending.
    scored.sort((a, b) => b.score.compareTo(a.score));

    // Take topK.
    final limited = scored.take(_config.recallTopK).toList();

    // Budget-aware cutoff.
    final results = <LabeledRecall>[];
    final accessedIds = <String>[];

    for (final s in limited) {
      final tokens = budget.consume(s.item.content);
      results.add(LabeledRecall(
        componentName: name,
        content: s.item.content,
        score: s.score,
        metadata: {
          'id': s.item.id,
          'category': s.item.category.name,
          'importance': s.item.importance,
          'tokens': tokens,
        },
      ));
      accessedIds.add(s.item.id);

      if (budget.isOverBudget) break;
    }

    // Update access stats.
    if (accessedIds.isNotEmpty) {
      await _store.updateAccessStats(accessedIds);
    }

    return results;
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  /// Tokenizes text for keyword overlap scoring.
  static Set<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 2)
        .toSet();
  }

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
