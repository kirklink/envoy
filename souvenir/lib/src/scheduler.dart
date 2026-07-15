import 'dart:async';
import 'dart:convert';

import 'engine.dart';
import 'llm_callback.dart';

/// Drives consolidation autonomically — a property of the system, not a
/// task any agent performs.
///
/// Ticks on a fixed interval and consolidates when either trigger fires:
/// the unconsolidated backlog reaches [minEpisodes], or the oldest pending
/// episode is older than [maxAge]. Runs once immediately on [start] so a
/// backlog accumulated while the host was down drains at boot.
///
/// Failure is contained by design: every tick swallows and logs its own
/// errors (an LLM outage must never kill the timer), episodes stay
/// unconsolidated for retry, and consecutive failures back the scheduler
/// off — skipping `min(failures, maxBackoffTicks)` ticks — so a keyless or
/// erroring deployment logs calmly instead of once per interval.
///
/// ```dart
/// final scheduler = ConsolidationScheduler(
///   engine: souvenir,
///   llm: llm,
///   onLog: (line) => logFile.writeAsStringSync('$line\n',
///       mode: FileMode.append),
/// )..start();
/// // ... on shutdown, before closing the database:
/// await scheduler.stop();
/// ```
class ConsolidationScheduler {
  /// The engine to consolidate. Its internal lock serializes this
  /// scheduler against any other caller (e.g. a manual MCP trigger).
  final Souvenir engine;

  /// LLM used for consolidation.
  final LlmCallback llm;

  /// Backlog size that triggers a run.
  final int minEpisodes;

  /// Age of the oldest pending episode that triggers a run — bounds how
  /// long a below-threshold trickle can sit unconsolidated.
  final Duration maxAge;

  /// How often triggers are checked. Checks are two cheap SQLite reads.
  final Duration tickInterval;

  /// Cap on consecutive-failure backoff, in skipped ticks.
  final int maxBackoffTicks;

  /// Sink for one JSON line per run or error. Must never throw.
  final void Function(String line) onLog;

  Timer? _timer;
  Future<void>? _inFlight;
  int _consecutiveFailures = 0;
  int _skipRemaining = 0;

  ConsolidationScheduler({
    required this.engine,
    required this.llm,
    required this.onLog,
    this.minEpisodes = 5,
    this.maxAge = const Duration(minutes: 20),
    this.tickInterval = const Duration(seconds: 60),
    this.maxBackoffTicks = 15,
  });

  /// Whether the periodic timer is running.
  bool get isRunning => _timer != null;

  /// Starts the loop: one immediate tick (boot catch-up), then periodic.
  /// Idempotent — calling on a started scheduler does nothing.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(tickInterval, (_) => tick());
    tick();
  }

  /// Stops the timer and waits for any in-flight consolidation, so the
  /// host can safely close the underlying database.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _inFlight;
  }

  /// One trigger check + consolidation if due. Public so hosts and tests
  /// can drive it deterministically; concurrent calls are skip-if-busy.
  Future<void> tick() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    return _inFlight = _guardedTick().whenComplete(() => _inFlight = null);
  }

  Future<void> _guardedTick() async {
    if (_skipRemaining > 0) {
      _skipRemaining--;
      return;
    }
    try {
      final count = engine.unconsolidatedEpisodeCount;
      if (count == 0) return;

      final oldest = engine.oldestUnconsolidatedAt;
      final age = oldest == null
          ? Duration.zero
          : DateTime.now().toUtc().difference(oldest.toUtc());
      final String trigger;
      if (count >= minEpisodes) {
        trigger = 'count';
      } else if (age >= maxAge) {
        trigger = 'age';
      } else {
        return;
      }

      final started = DateTime.now().toUtc();
      final reports = await engine.consolidate(llm);
      _consecutiveFailures = 0;
      onLog(jsonEncode({
        'ts': started.toIso8601String(),
        'trigger': trigger,
        'episodes': count,
        'oldest_age_s': age.inSeconds,
        'duration_ms':
            DateTime.now().toUtc().difference(started).inMilliseconds,
        'reports': [
          for (final r in reports)
            {
              'component': r.componentName,
              'created': r.itemsCreated,
              'merged': r.itemsMerged,
              'decayed': r.itemsDecayed,
              'consumed': r.episodesConsumed,
            },
        ],
      }));
    } catch (e) {
      _consecutiveFailures++;
      _skipRemaining = _consecutiveFailures > maxBackoffTicks
          ? maxBackoffTicks
          : _consecutiveFailures;
      onLog(jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'error': e.toString(),
        'consecutive_failures': _consecutiveFailures,
        'backoff_ticks': _skipRemaining,
      }));
    }
  }
}
