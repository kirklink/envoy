import 'dart:math' as math;

import 'config.dart';
import 'embedding_provider.dart';
import 'llm_callback.dart';
import 'store/souvenir_store.dart';

/// Level of personality reset.
enum ResetLevel {
  /// LLM recalibrates personality toward identity (requires LlmCallback).
  soft,

  /// Restores a historical snapshot by date.
  rollback,

  /// Overwrites personality with identity text.
  hard,
}

const _softResetSystemPrompt = '''
You are recalibrating an agent's personality toward its core identity.
Given the core identity and the current (drifted) personality, produce an
updated personality that is closer to the identity while preserving any
genuinely valuable adaptations. Third-person observational prose. Output
only the new personality text, no explanation.
''';

/// Manages immutable identity + mutable personality backed by SQLite.
///
/// Identity is caller-provided and never written to the database. Personality
/// text, history snapshots, and timestamps are stored in the `personality` and
/// `personality_history` tables.
class PersonalityManager {
  final SouvenirStore _store;
  final SouvenirConfig _config;
  final EmbeddingProvider? _embeddings;

  String? _identityText;
  String? _personalityText;
  DateTime? _lastUpdated;

  PersonalityManager(
    this._store, {
    String? identityText,
    SouvenirConfig config = const SouvenirConfig(),
    EmbeddingProvider? embeddings,
  })  : _identityText = identityText,
        _config = config,
        _embeddings = embeddings;

  /// Loads personality state from the database.
  ///
  /// If no personality exists but identity text is available, seeds the
  /// personality with the identity text (no history snapshot).
  Future<void> initialize() async {
    _personalityText = await _store.getPersonality();
    _lastUpdated = await _store.getPersonalityLastUpdated();

    // Seed personality from identity on first run.
    if (_personalityText == null && _identityText != null) {
      await _store.initPersonality(_identityText!);
      _personalityText = _identityText;
      _lastUpdated = DateTime.now().toUtc();
    }
  }

  /// The immutable core identity text (caller-provided).
  String? get identity => _identityText;

  /// The current personality text (mutable, stored in DB).
  String? get personality => _personalityText;

  /// When the personality was last updated.
  DateTime? get lastUpdated => _lastUpdated;

  /// Updates the personality text if drift exceeds the configured threshold.
  ///
  /// Returns `true` if the update was applied, `false` if skipped due to
  /// insufficient drift.
  Future<bool> updatePersonality(String newText) async {
    // Always update if no current personality or no embeddings.
    if (_personalityText != null && _embeddings != null) {
      try {
        final oldVec = await _embeddings!.embed(_personalityText!);
        final newVec = await _embeddings!.embed(newText);
        final distance = 1.0 - _cosineSimilarity(oldVec, newVec);
        if (distance < _config.minPersonalityDrift) {
          return false;
        }
      } catch (_) {
        // Embedding failure — proceed with update.
      }
    }

    await _store.savePersonality(newText);
    _personalityText = newText;
    _lastUpdated = DateTime.now().toUtc();
    return true;
  }

  /// Resets the personality to a previous state.
  ///
  /// - [ResetLevel.hard]: overwrites personality with identity text.
  /// - [ResetLevel.rollback]: restores the nearest snapshot on or before [date].
  /// - [ResetLevel.soft]: LLM recalibrates personality toward identity
  ///   (requires [llm]).
  Future<void> reset(
    ResetLevel level, {
    LlmCallback? llm,
    DateTime? date,
  }) async {
    switch (level) {
      case ResetLevel.hard:
        if (_identityText == null) {
          throw StateError('Cannot hard-reset: no identity text configured.');
        }
        await _store.savePersonality(_identityText!);
        _personalityText = _identityText;
        _lastUpdated = DateTime.now().toUtc();

      case ResetLevel.rollback:
        if (date == null) {
          throw ArgumentError('rollback requires a date');
        }
        final snapshot = await _store.personalityHistoryAt(date);
        if (snapshot == null) {
          throw StateError('No personality snapshot found on or before $date');
        }
        await _store.savePersonality(snapshot);
        _personalityText = snapshot;
        _lastUpdated = DateTime.now().toUtc();

      case ResetLevel.soft:
        if (llm == null) {
          throw ArgumentError('soft reset requires an LlmCallback');
        }
        if (_identityText == null || _personalityText == null) {
          throw StateError(
            'Cannot soft-reset: identity and personality must both exist.',
          );
        }
        final userPrompt =
            'Core identity:\n$_identityText\n\n'
            'Current personality:\n$_personalityText';
        final newText = await llm(_softResetSystemPrompt, userPrompt);
        await updatePersonality(newText);
    }
  }

  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    var dot = 0.0, normA = 0.0, normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    final denom = math.sqrt(normA) * math.sqrt(normB);
    return denom == 0 ? 0.0 : dot / denom;
  }
}
