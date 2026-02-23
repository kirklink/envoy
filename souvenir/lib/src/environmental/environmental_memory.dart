import 'dart:convert';
import 'dart:math' as math;

import '../budget.dart';
import '../labeled_recall.dart';
import '../llm_callback.dart';
import '../memory_component.dart';
import '../models/episode.dart';
import 'environmental_item.dart';
import 'environmental_memory_config.dart';
import 'environmental_memory_store.dart';

const _systemPrompt = '''
You are reflecting on what you learned about your own operating environment,
capabilities, and constraints from recent experience. This is self-awareness —
not task context and not long-term facts about the user.

Output a JSON object with this exact structure (no other text):

{
  "observations": [
    {
      "content": "A standalone observation about your environment",
      "category": "capability|constraint|environment|pattern",
      "importance": 0.7,
      "action": "new|merge"
    }
  ]
}

Category definitions:
- "capability": What you can do — tools available, APIs accessible, file system
  operations, language/runtime features you observed working.
- "constraint": Limitations you encountered — rate limits, access restrictions,
  size limits, permission boundaries, things that failed or were unavailable.
- "environment": System context — OS, project structure, runtime info, directory
  layout, installed packages, infrastructure details you observed.
- "pattern": Behavioral patterns — how the user communicates, workflow habits,
  system response patterns, your own behavioral tendencies you noticed.

Rules:
- Reflect on YOUR environment and capabilities, not the user's task.
- Each observation should be a standalone statement — understandable without context.
- Importance: constraints 0.7-0.9, capabilities 0.6-0.8, environment 0.5-0.7, patterns 0.4-0.6.
- Set "action" to "merge" if this refines something you likely already observed.
  Set to "new" for genuinely new environmental awareness.
- Do NOT extract task goals, decisions, or results — those belong in task memory.
- Do NOT extract long-term user preferences or project facts — those belong in durable memory.
- If nothing about the environment is worth noting, return: {"observations": []}
''';

/// Environmental memory component: LLM self-awareness of operating context.
///
/// Implements [MemoryComponent] with:
/// - Self-reflective LLM extraction (capabilities, constraints, environment, patterns)
/// - Cross-session persistence (no session boundary expiration)
/// - Medium decay (days/weeks via importance decay)
/// - Category-weighted recall with recency boost on days scale
class EnvironmentalMemory implements MemoryComponent {
  @override
  final String name;

  final EnvironmentalMemoryStore _store;
  final EnvironmentalMemoryConfig _config;

  EnvironmentalMemory({
    this.name = 'environmental',
    EnvironmentalMemoryStore? store,
    EnvironmentalMemoryConfig? config,
  })  : _store = store ?? InMemoryEnvironmentalMemoryStore(),
        _config = config ?? const EnvironmentalMemoryConfig();

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
    // Always apply importance decay, even for empty episodes.
    final itemsDecayed = await _store.applyImportanceDecay(
      inactivePeriod: _config.decayInactivePeriod,
      decayRate: _config.importanceDecayRate,
      floorThreshold: _config.decayFloorThreshold,
    );

    if (episodes.isEmpty) {
      return ConsolidationReport(
        componentName: name,
        itemsDecayed: itemsDecayed,
      );
    }

    // Build episode transcript.
    final buffer = StringBuffer();
    for (final ep in episodes) {
      buffer.writeln('[${ep.type.name}] ${ep.content}');
    }

    // Call LLM for self-reflective extraction.
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

    final observations = extraction['observations'] as List<dynamic>? ?? [];
    for (final rawObs in observations) {
      final obsMap = rawObs as Map<String, dynamic>;
      final content = obsMap['content'] as String;
      final categoryName = obsMap['category'] as String? ?? 'environment';
      final category = EnvironmentalCategory.values.firstWhere(
        (c) => c.name == categoryName,
        orElse: () => EnvironmentalCategory.environment,
      );
      final importance = (obsMap['importance'] as num?)?.toDouble() ??
          _config.defaultImportance;
      final action = obsMap['action'] as String? ?? 'new';

      // Merge action: find existing similar observation in the same category.
      if (action == 'merge') {
        final similar = await _store.findSimilar(content, category);
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

      // Enforce maxItems.
      final activeCount = await _store.activeItemCount();
      if (activeCount >= _config.maxItems) {
        final activeItems = await _store.allActiveItems();
        if (activeItems.isNotEmpty) {
          activeItems.sort((a, b) => a.importance.compareTo(b.importance));
          await _store.markDecayed(activeItems.first.id);
        }
      }

      await _store.insert(EnvironmentalItem(
        content: content,
        category: category,
        importance: importance,
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
    final items = await _store.allActiveItems();
    if (items.isEmpty) return [];

    final queryTokens = _tokenize(query);
    final now = DateTime.now().toUtc();
    final scored = <({EnvironmentalItem item, double score})>[];

    for (final item in items) {
      final itemTokens = _tokenize(item.content);

      // Signal 1: Keyword overlap (Jaccard similarity).
      double keywordScore;
      if (queryTokens.isEmpty || itemTokens.isEmpty) {
        keywordScore = 0.05;
      } else {
        final intersection = queryTokens.intersection(itemTokens);
        final union = queryTokens.union(itemTokens);
        keywordScore =
            union.isEmpty ? 0.05 : intersection.length / union.length;
        if (keywordScore == 0) keywordScore = 0.05;
      }

      // Signal 2: Recency boost (days scale).
      final ageDays = now.difference(item.createdAt).inHours / 24.0;
      final recencyMultiplier =
          math.exp(-_config.recencyDecayLambda * math.max(0, ageDays));

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
