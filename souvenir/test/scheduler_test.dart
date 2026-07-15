import 'dart:async';
import 'dart:convert';

import 'package:souvenir/souvenir.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

Episode _episode(String content, {DateTime? timestamp}) {
  return Episode(
    sessionId: 'ses_01',
    type: EpisodeType.observation,
    content: content,
    timestamp: timestamp,
  );
}

/// Component with an optional async delay and failure switch, so tests can
/// hold a consolidation in flight or make it throw.
class ProbeComponent implements MemoryComponent {
  @override
  final String name = 'probe';

  int consolidateCount = 0;
  Duration delay = Duration.zero;
  bool fail = false;
  Completer<void>? gate;

  @override
  Future<void> initialize() async {}

  @override
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
  ) async {
    consolidateCount++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final g = gate;
    if (g != null) await g.future;
    if (fail) throw StateError('llm exploded');
    return ConsolidationReport(
      componentName: name,
      itemsCreated: 1,
      episodesConsumed: episodes.length,
    );
  }

  @override
  Future<void> close() async {}
}

Future<String> _noopLlm(String system, String user) async => '';

(Souvenir, ProbeComponent) _engine() {
  final component = ProbeComponent();
  final engine = Souvenir(
    components: [component],
    store: InMemoryMemoryStore(),
  );
  return (engine, component);
}

ConsolidationScheduler _scheduler(
  Souvenir engine,
  List<Map<String, dynamic>> log, {
  int minEpisodes = 5,
  Duration maxAge = const Duration(minutes: 20),
  Duration tickInterval = const Duration(seconds: 60),
}) {
  return ConsolidationScheduler(
    engine: engine,
    llm: _noopLlm,
    onLog: (line) => log.add(jsonDecode(line) as Map<String, dynamic>),
    minEpisodes: minEpisodes,
    maxAge: maxAge,
    tickInterval: tickInterval,
  );
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('engine consolidate() serialization', () {
    test('concurrent calls do not double-process episodes', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      await engine.record(_episode('one'));
      component.gate = Completer<void>();

      final first = engine.consolidate(_noopLlm);
      final second = engine.consolidate(_noopLlm);
      // Let the first call reach the component before releasing it.
      await Future<void>.delayed(Duration.zero);
      component.gate!.complete();

      final firstReports = await first;
      final secondReports = await second;

      expect(component.consolidateCount, 1,
          reason: 'second caller must see an already-consumed backlog');
      expect(firstReports, hasLength(1));
      expect(secondReports, isEmpty);
    });

    test('a failed call does not poison the lock for the next caller',
        () async {
      final (engine, component) = _engine();
      await engine.initialize();
      await engine.record(_episode('one'));

      component.fail = true;
      await expectLater(engine.consolidate(_noopLlm), throwsStateError);
      expect(engine.unconsolidatedEpisodeCount, 1,
          reason: 'failed consolidation must retain episodes for retry');

      component.fail = false;
      final reports = await engine.consolidate(_noopLlm);
      expect(reports, hasLength(1));
      expect(engine.unconsolidatedEpisodeCount, 0);
    });
  });

  group('backlog observability', () {
    test('count and oldest include buffered (unflushed) episodes', () async {
      final (engine, _) = _engine();
      await engine.initialize();
      final old = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      await engine.record(_episode('buffered', timestamp: old));

      expect(engine.unconsolidatedEpisodeCount, 1);
      expect(engine.oldestUnconsolidatedAt, old);
    });
  });

  group('ConsolidationScheduler triggers', () {
    test('no-op below both thresholds', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = _scheduler(engine, log);

      await engine.record(_episode('fresh'));
      await scheduler.tick();

      expect(component.consolidateCount, 0);
      expect(log, isEmpty);
    });

    test('count trigger fires at minEpisodes', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = _scheduler(engine, log, minEpisodes: 3);

      for (var i = 0; i < 3; i++) {
        await engine.record(_episode('e$i'));
      }
      await scheduler.tick();

      expect(component.consolidateCount, 1);
      expect(log.single['trigger'], 'count');
      expect(log.single['episodes'], 3);
      final reports = log.single['reports'] as List;
      expect((reports.single as Map)['consumed'], 3);
      expect(engine.unconsolidatedEpisodeCount, 0);
    });

    test('age trigger fires for a stale below-threshold trickle', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler =
          _scheduler(engine, log, maxAge: const Duration(minutes: 20));

      await engine.record(_episode('stale',
          timestamp:
              DateTime.now().toUtc().subtract(const Duration(minutes: 30))));
      await scheduler.tick();

      expect(component.consolidateCount, 1);
      expect(log.single['trigger'], 'age');
      expect(log.single['oldest_age_s'], greaterThan(20 * 60));
    });
  });

  group('ConsolidationScheduler failure containment', () {
    test('errors are logged, episodes retained, and backoff skips ticks',
        () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = _scheduler(engine, log, minEpisodes: 1);
      component.fail = true;

      await engine.record(_episode('doomed'));
      await scheduler.tick();

      expect(log.single['error'], contains('llm exploded'));
      expect(log.single['consecutive_failures'], 1);
      expect(log.single['backoff_ticks'], 1);
      expect(engine.unconsolidatedEpisodeCount, 1);

      // Backoff: the next tick is skipped entirely.
      await scheduler.tick();
      expect(component.consolidateCount, 1);
      expect(log, hasLength(1));

      // After the skip, it retries — and a success resets the counter.
      component.fail = false;
      await scheduler.tick();
      expect(component.consolidateCount, 2);
      expect(log.last['trigger'], 'count');
    });

    test('escalating failures cap at maxBackoffTicks', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = ConsolidationScheduler(
        engine: engine,
        llm: _noopLlm,
        onLog: (line) => log.add(jsonDecode(line) as Map<String, dynamic>),
        minEpisodes: 1,
        maxBackoffTicks: 2,
      );
      component.fail = true;
      await engine.record(_episode('doomed'));

      await scheduler.tick(); // failure 1 → skip 1
      await scheduler.tick(); // skipped
      await scheduler.tick(); // failure 2 → skip 2
      await scheduler.tick(); // skipped
      await scheduler.tick(); // skipped
      await scheduler.tick(); // failure 3 → skip capped at 2

      final errors = log.where((l) => l.containsKey('error')).toList();
      expect(errors, hasLength(3));
      expect(errors.last['consecutive_failures'], 3);
      expect(errors.last['backoff_ticks'], 2);
    });
  });

  group('ConsolidationScheduler lifecycle', () {
    test('overlapping ticks share one run', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = _scheduler(engine, log, minEpisodes: 1);
      component.gate = Completer<void>();

      await engine.record(_episode('one'));
      final first = scheduler.tick();
      final second = scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      component.gate!.complete();
      await Future.wait([first, second]);

      expect(component.consolidateCount, 1);
      expect(log, hasLength(1));
    });

    test('stop() awaits the in-flight tick', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = _scheduler(engine, log, minEpisodes: 1);
      component.gate = Completer<void>();

      await engine.record(_episode('one'));
      final ticking = scheduler.tick();
      // Release the gate shortly after stop() starts waiting.
      Future<void>.delayed(const Duration(milliseconds: 10))
          .then((_) => component.gate!.complete());
      await scheduler.stop();

      expect(component.consolidateCount, 1);
      expect(log, hasLength(1), reason: 'stop() must not truncate the run');
      await ticking;
    });

    test('start() is idempotent and drains a boot backlog', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = _scheduler(
        engine,
        log,
        minEpisodes: 1,
        tickInterval: const Duration(hours: 1),
      );

      await engine.record(_episode('accumulated while down'));
      scheduler.start();
      scheduler.start();
      expect(scheduler.isRunning, isTrue);

      // The immediate boot tick drains the backlog without waiting an hour.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(component.consolidateCount, 1);

      await scheduler.stop();
      expect(scheduler.isRunning, isFalse);
    });

    test('periodic timer fires ticks on its own', () async {
      final (engine, component) = _engine();
      await engine.initialize();
      final log = <Map<String, dynamic>>[];
      final scheduler = _scheduler(
        engine,
        log,
        minEpisodes: 1,
        tickInterval: const Duration(milliseconds: 20),
      );

      scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // Backlog arrives after the boot tick; only the timer can see it.
      await engine.record(_episode('late arrival'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await scheduler.stop();

      expect(component.consolidateCount, 1);
      expect(log.single['trigger'], 'count');
    });
  });
}
