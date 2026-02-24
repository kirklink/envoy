/// Grid search over RecallConfig weights to find the best combination.
///
/// Runs all weight combinations through the full eval harness and ranks
/// them by MRR. Prints the top results and the winning config.
///
/// Usage:
/// ```
/// dart run bin/tune.dart
/// dart run bin/tune.dart --top 10       # show top 10 instead of 5
/// dart run bin/tune.dart --save         # save best config to eval/best.md
/// ```
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:souvenir/src/eval/report.dart';
import 'package:souvenir/src/eval/runner.dart';
import 'package:souvenir/src/eval/scenarios.dart';
import 'package:souvenir/src/eval/types.dart';
import 'package:souvenir/src/recall.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('top',
        defaultsTo: '5',
        help: 'Number of top results to show')
    ..addFlag('save',
        defaultsTo: false,
        negatable: false,
        help: 'Write best config + full results to eval/tune.md')
    ..addFlag('help',
        abbr: 'h',
        negatable: false,
        help: 'Show this help');

  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    print('dart run bin/tune.dart [options]\n${parser.usage}');
    return;
  }

  final topN = int.parse(parsed['top'] as String);
  final save = parsed['save'] as bool;

  // ── Grid definition ─────────────────────────────────────────────────────

  const ftsWeights = [0.5, 1.0, 1.5, 2.0];
  const vecWeights = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0];
  const entityWeights = [0.3, 0.5, 0.8, 1.0, 1.5];
  // threshold and decay are held constant — they're noise/time parameters
  // better tuned with real data rather than fake embeddings.

  final total = ftsWeights.length * vecWeights.length * entityWeights.length;
  print('Grid search: ${ftsWeights.length} fts × ${vecWeights.length} vec × ${entityWeights.length} entity = $total combinations');
  print('');

  // ── Run all combinations ─────────────────────────────────────────────────

  final allResults = <_TuneResult>[];
  var done = 0;
  final startTime = DateTime.now();

  for (final fts in ftsWeights) {
    for (final vec in vecWeights) {
      for (final entity in entityWeights) {
        final config = RecallConfig(
          ftsWeight: fts,
          vectorWeight: vec,
          entityWeight: entity,
        );

        final runner = EvalRunner(config: config);
        final summary =
            await runner.runAll(defaultScenarios, embeddingMode: 'fake');

        allResults.add(_TuneResult(config: config, summary: summary));

        done++;
        // Progress indicator every 10 runs.
        if (done % 10 == 0 || done == total) {
          final pct = (done * 100 ~/ total).toString().padLeft(3);
          stdout.write('\r  $pct%  ($done/$total)  ');
        }
      }
    }
  }

  final elapsed = DateTime.now().difference(startTime).inMilliseconds;
  print('\r  Done. ${total} runs in ${elapsed}ms (${(elapsed / total).round()}ms each)');
  print('');

  // ── Rank by MRR ──────────────────────────────────────────────────────────

  allResults.sort((a, b) {
    final mrrCmp = b.summary.overallMrr.compareTo(a.summary.overallMrr);
    if (mrrCmp != 0) return mrrCmp;
    // Tiebreak: pass count, then lowest entity weight (simpler model).
    final passCmp =
        b.summary.passedQueries.compareTo(a.summary.passedQueries);
    if (passCmp != 0) return passCmp;
    return a.config.entityWeight.compareTo(b.config.entityWeight);
  });

  final best = allResults.first;
  final worst = allResults.last;

  // ── Print results ─────────────────────────────────────────────────────────

  print('Top $topN configurations by MRR:');
  print('');
  print(
      '${_pad('Rank', 5)}  ${_pad('MRR', 5)}  ${_pad('Pass', 6)}  ${_pad('fts', 5)}  ${_pad('vec', 5)}  entity');
  print('─' * 42);

  for (var i = 0; i < topN && i < allResults.length; i++) {
    final r = allResults[i];
    final passStr = '${r.summary.passedQueries}/${r.summary.totalQueries}';
    print(
        '${_pad('#${i + 1}', 5)}  ${_pad(r.summary.overallMrr.toStringAsFixed(3), 5)}  ${_pad(passStr, 6)}  ${_pad(r.config.ftsWeight.toString(), 5)}  ${_pad(r.config.vectorWeight.toString(), 5)}  ${r.config.entityWeight}');
  }

  print('─' * 42);
  print(
      '${_pad('worst', 5)}  ${_pad(worst.summary.overallMrr.toStringAsFixed(3), 5)}  ${worst.summary.passedQueries}/${worst.summary.totalQueries}  fts=${worst.config.ftsWeight} vec=${worst.config.vectorWeight} entity=${worst.config.entityWeight}');
  print('');

  // ── Best config detail ───────────────────────────────────────────────────

  print('Best config:  fts=${best.config.ftsWeight}  vec=${best.config.vectorWeight}  entity=${best.config.entityWeight}');
  print('');
  print('Per-scenario breakdown for best config:');
  print('');
  print('${_pad('Scenario', 24)}  ${_pad('Pass', 6)}  MRR');
  print('─' * 40);
  for (final sr in best.summary.scenarioResults) {
    final passStr = '${sr.passedQueries}/${sr.totalQueries}';
    final icon = sr.passedQueries == sr.totalQueries ? '✓' : '✗';
    print('$icon ${_pad(sr.scenario.name, 23)}  ${_pad(passStr, 6)}  ${sr.mrr.toStringAsFixed(2)}');
  }
  print('─' * 40);
  print('  ${_pad('TOTAL', 23)}  ${best.summary.passedQueries}/${best.summary.totalQueries}   ${best.summary.overallMrr.toStringAsFixed(2)}');
  print('');

  // ── Scenario-level winners ────────────────────────────────────────────────

  print('Best config per scenario:');
  print('');
  for (final scenario in defaultScenarios) {
    final name = scenario.name;
    final best = allResults
        .reduce((a, b) {
          final aSr =
              a.summary.scenarioResults.firstWhere((r) => r.scenario.name == name);
          final bSr =
              b.summary.scenarioResults.firstWhere((r) => r.scenario.name == name);
          final mrrCmp = bSr.mrr.compareTo(aSr.mrr);
          if (mrrCmp != 0) return mrrCmp > 0 ? b : a;
          return bSr.passedQueries >= aSr.passedQueries ? b : a;
        });
    final sr = best.summary.scenarioResults
        .firstWhere((r) => r.scenario.name == name);
    print('  $name: MRR ${sr.mrr.toStringAsFixed(2)} @ fts=${best.config.ftsWeight} vec=${best.config.vectorWeight} entity=${best.config.entityWeight}');
  }
  print('');

  // ── Current default comparison ────────────────────────────────────────────

  final defaultConfig = RecallConfig();
  final defaultResult = allResults.firstWhere(
    (r) =>
        r.config.ftsWeight == defaultConfig.ftsWeight &&
        r.config.vectorWeight == defaultConfig.vectorWeight &&
        r.config.entityWeight == defaultConfig.entityWeight,
    orElse: () => allResults.last,
  );
  final defaultRank =
      allResults.indexOf(defaultResult) + 1;
  print('Current default (fts=1.0 vec=1.5 entity=0.8):  MRR ${defaultResult.summary.overallMrr.toStringAsFixed(3)}  rank #$defaultRank/$total');
  print('Best (fts=${allResults.first.config.ftsWeight} vec=${allResults.first.config.vectorWeight} entity=${allResults.first.config.entityWeight}):  MRR ${allResults.first.summary.overallMrr.toStringAsFixed(3)}  rank #1/$total');
  print('');

  // ── Save ─────────────────────────────────────────────────────────────────

  if (save) {
    final report = EvalReport();
    Directory('eval').createSync(recursive: true);
    final bestSummary = allResults.first.summary;
    File('eval/tune.md').writeAsStringSync(
      '# Tuning Results\n\n'
      '**Grid:** fts=${ftsWeights}  vec=$vecWeights  entity=$entityWeights\n'
      '**Total combinations:** $total\n\n'
      '## Best Config\n\n'
      '```\nfts=${allResults.first.config.ftsWeight}  '
      'vec=${allResults.first.config.vectorWeight}  '
      'entity=${allResults.first.config.entityWeight}\n```\n\n'
      '## Full Report\n\n'
      '${report.toMarkdown(bestSummary)}',
    );
    print('Saved → eval/tune.md');
  }

  print('To use the best config:');
  print('  dart run bin/eval.dart --fts-weight ${allResults.first.config.ftsWeight} --vec-weight ${allResults.first.config.vectorWeight} --entity-weight ${allResults.first.config.entityWeight}');
}

// ── Types ─────────────────────────────────────────────────────────────────────

class _TuneResult {
  final RecallConfig config;
  final RunSummary summary;
  const _TuneResult({required this.config, required this.summary});
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _pad(String s, int width) {
  if (s.length >= width) return s.substring(0, width);
  return s.padRight(width);
}
