import 'dart:convert';
import 'dart:math' as math;

import '../llm_callback.dart';
import '../memory_component.dart';
import '../memory_store.dart';
import '../models/episode.dart';
import '../stored_memory.dart';
import 'environmental_memory_config.dart';

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
/// Writes to the shared [MemoryStore] with `component: 'environmental'`.
/// Recall is handled by the engine's unified recall pipeline.
class EnvironmentalMemory implements MemoryComponent {
  @override
  final String name;

  final MemoryStore _store;
  final EnvironmentalMemoryConfig _config;

  EnvironmentalMemory({
    this.name = 'environmental',
    required MemoryStore store,
    EnvironmentalMemoryConfig? config,
  })  : _store = store,
        _config = config ?? const EnvironmentalMemoryConfig();

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
    // Always apply importance decay, even for empty episodes.
    final itemsDecayed = await _store.applyImportanceDecay(
      component: name,
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
      final importance = (obsMap['importance'] as num?)?.toDouble() ??
          _config.defaultImportance;
      final action = obsMap['action'] as String? ?? 'new';

      // Merge action: find existing similar observation in the same category.
      if (action == 'merge') {
        final similar = await _store.findSimilar(
          content,
          name,
          category: categoryName,
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

      await _store.insert(StoredMemory(
        content: content,
        component: name,
        category: categoryName,
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
