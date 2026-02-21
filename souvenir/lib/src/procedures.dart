import 'config.dart';
import 'store/souvenir_store.dart';

/// A task-specific procedure with keyword matching.
class Procedure {
  /// Canonical task type name (e.g., "debugging", "code_review").
  final String taskType;

  /// The procedure text (how-to content).
  final String content;

  /// Keywords derived from [taskType] for matching against session intents.
  final List<String> keywords;

  const Procedure({
    required this.taskType,
    required this.content,
    required this.keywords,
  });
}

/// Manages procedural memory: task-specific how-to knowledge + pattern tracking.
///
/// Procedures are provided at construction (caller-owned). Pattern tracking
/// (success/failure per task type) is persisted in SQLite.
class ProcedureManager {
  final SouvenirStore _store;
  final SouvenirConfig _config;
  final List<Procedure> _procedures = [];

  ProcedureManager(this._store, this._config);

  /// Parses the procedure map into [Procedure] objects with auto-generated
  /// keywords.
  void initialize(Map<String, String>? procedures) {
    _procedures.clear();
    if (procedures == null) return;

    for (final entry in procedures.entries) {
      _procedures.add(Procedure(
        taskType: entry.key,
        content: entry.value,
        keywords: _generateKeywords(entry.key),
      ));
    }
  }

  /// Returns procedure content strings matching the [sessionIntent].
  ///
  /// Uses keyword substring matching. Results are token-budgeted by
  /// [SouvenirConfig.maxProcedureTokens].
  List<String> matchFor(String sessionIntent) {
    if (_procedures.isEmpty) return const [];

    final lowerIntent = sessionIntent.toLowerCase();
    final matched = <String>[];
    var tokenCount = 0;
    final divisor = _config.tokenEstimationDivisor;
    final budget = _config.maxProcedureTokens;

    for (final proc in _procedures) {
      final isMatch = proc.keywords.any(lowerIntent.contains);
      if (!isMatch) continue;

      final tokens = (proc.content.length / divisor).ceil();
      if (tokenCount + tokens > budget) break;

      matched.add(proc.content);
      tokenCount += tokens;
    }

    return matched;
  }

  /// Records a task outcome for pattern tracking.
  Future<void> recordOutcome({
    required String taskType,
    required bool success,
    required String sessionId,
    String? notes,
  }) async {
    await _store.insertPattern(
      taskType: taskType,
      success: success,
      sessionId: sessionId,
      notes: notes,
    );
  }

  /// Returns a brief text summary of the track record for [taskType].
  ///
  /// Returns null if no patterns exist for this task type.
  Future<String?> patternSummary(String taskType) async {
    final stats = await _store.getPatternStats(taskType);
    final total = stats.successes + stats.failures;
    if (total == 0) return null;

    final buffer = StringBuffer(
      'Track record for $taskType: '
      '${stats.successes}/$total successful.',
    );

    if (stats.recentNotes.isNotEmpty) {
      buffer.writeln();
      buffer.write('Recent issues: ');
      buffer.write(stats.recentNotes.join('; '));
    }

    return buffer.toString();
  }

  /// The loaded procedures (for testing/inspection).
  List<Procedure> get procedures => List.unmodifiable(_procedures);

  /// Generates keywords from a task type name.
  ///
  /// "code_review" → ["code_review", "code review", "code-review", "code", "review"]
  /// "debugging" → ["debugging", "debug"]
  static List<String> _generateKeywords(String taskType) {
    final lower = taskType.toLowerCase();
    final keywords = <String>{lower};

    // Add space/hyphen variants of underscore-separated names.
    if (lower.contains('_')) {
      keywords.add(lower.replaceAll('_', ' '));
      keywords.add(lower.replaceAll('_', '-'));
      keywords.addAll(lower.split('_'));
    }
    if (lower.contains('-')) {
      keywords.add(lower.replaceAll('-', ' '));
      keywords.add(lower.replaceAll('-', '_'));
      keywords.addAll(lower.split('-'));
    }

    // Add common stem: remove trailing "ging", "ing", "tion" for partial match.
    if (lower.endsWith('ging')) {
      keywords.add(lower.substring(0, lower.length - 4));
    } else if (lower.endsWith('ing')) {
      keywords.add(lower.substring(0, lower.length - 3));
    }

    return keywords.toList();
  }
}
