import 'dart:convert';

import '../recall.dart';
import 'scenarios.dart';
import 'types.dart';

/// Formats [RunSummary] results for console output, markdown, and JSONL.
class EvalReport {
  const EvalReport();

  // ── Console output ──────────────────────────────────────────────────────

  /// Returns a human-readable console summary with optional delta vs [previous].
  String toConsole(RunSummary summary, {RunSummary? previous}) {
    final delta =
        previous != null ? RunDelta(previous: previous, current: summary) : null;
    final buf = StringBuffer();

    // Header.
    buf.writeln('Souvenir Recall Eval  —  ${_fmtTimestamp(summary.timestamp)}');
    buf.writeln(_configLine(summary.config));
    buf.writeln('Embeddings: ${summary.embeddingMode}');
    buf.writeln();

    // Table header.
    if (delta != null) {
      buf.writeln(
          '${_pad('Scenario', 24)}  ${_pad('Q', 4)}  ${_pad('Pass', 6)}  ${_pad('MRR', 5)}  ${_pad('Δ pass', 7)}  ${_pad('Δ MRR', 6)}');
      buf.writeln('─' * 64);
    } else {
      buf.writeln(
          '${_pad('Scenario', 24)}  ${_pad('Q', 4)}  ${_pad('Pass', 6)}  MRR');
      buf.writeln('─' * 44);
    }

    // Per-scenario rows.
    for (final sr in summary.scenarioResults) {
      final passStr = '${sr.passedQueries}/${sr.totalQueries}';
      final mrrStr = sr.mrr.toStringAsFixed(2);

      if (delta != null) {
        final dPass = delta.scenarioPassDeltas[sr.scenario.name];
        final dMrr = delta.scenarioMrrDeltas[sr.scenario.name];
        final dPassStr = dPass == null
            ? '  new'
            : (dPass >= 0 ? '+$dPass' : '$dPass').padLeft(6);
        final dMrrStr = dMrr == null
            ? '   new'
            : _fmtDelta(dMrr).padLeft(6);
        buf.writeln(
            '${_pad(sr.scenario.name, 24)}  ${_pad(sr.totalQueries.toString(), 4)}  ${_pad(passStr, 6)}  ${_pad(mrrStr, 5)}  $dPassStr  $dMrrStr');
      } else {
        buf.writeln(
            '${_pad(sr.scenario.name, 24)}  ${_pad(sr.totalQueries.toString(), 4)}  ${_pad(passStr, 6)}  $mrrStr');
      }
    }

    // Totals row.
    final totalPassStr = '${summary.passedQueries}/${summary.totalQueries}';
    final totalMrrStr = summary.overallMrr.toStringAsFixed(2);
    if (delta != null) {
      buf.writeln('─' * 64);
      final dPassDiff =
          (summary.passedQueries - delta.previous.passedQueries).toDouble();
      final dPassStr = _fmtDelta(dPassDiff).padLeft(6);
      final dMrrStr = _fmtDelta(delta.mrrDelta).padLeft(6);
      buf.writeln(
          '${_pad('TOTAL', 24)}  ${_pad(summary.totalQueries.toString(), 4)}  ${_pad(totalPassStr, 6)}  ${_pad(totalMrrStr, 5)}  $dPassStr  $dMrrStr');
    } else {
      buf.writeln('─' * 44);
      buf.writeln(
          '${_pad('TOTAL', 24)}  ${_pad(summary.totalQueries.toString(), 4)}  ${_pad(totalPassStr, 6)}  $totalMrrStr');
    }

    buf.writeln();

    if (delta != null) {
      final mrrChange = delta.mrrDelta;
      final direction = mrrChange > 0.001
          ? '▲ improved'
          : mrrChange < -0.001
              ? '▼ regressed'
              : '= no change';
      buf.writeln('Overall MRR: $direction  '
          '(${delta.previous.overallMrr.toStringAsFixed(3)} → '
          '${summary.overallMrr.toStringAsFixed(3)})');
      buf.writeln();
    }

    return buf.toString();
  }

  // ── Markdown ────────────────────────────────────────────────────────────

  /// Returns a detailed markdown report with per-query breakdowns.
  String toMarkdown(RunSummary summary, {RunSummary? previous}) {
    final delta =
        previous != null ? RunDelta(previous: previous, current: summary) : null;
    final buf = StringBuffer();

    buf.writeln('# Souvenir Recall Evaluation');
    buf.writeln();
    buf.writeln('**Run:** ${_fmtTimestamp(summary.timestamp)}  ');
    buf.writeln('**Config:** ${_configLine(summary.config)}  ');
    buf.writeln('**Embeddings:** ${summary.embeddingMode}');
    buf.writeln();

    // Summary table.
    buf.writeln('## Summary');
    buf.writeln();
    if (delta != null) {
      buf.writeln('| Scenario | Queries | Pass | MRR | Δ pass | Δ MRR |');
      buf.writeln('|---|---|---|---|---|---|');
    } else {
      buf.writeln('| Scenario | Queries | Pass | MRR |');
      buf.writeln('|---|---|---|---|');
    }

    for (final sr in summary.scenarioResults) {
      final passStr = '${sr.passedQueries}/${sr.totalQueries}';
      final mrrStr = sr.mrr.toStringAsFixed(2);
      if (delta != null) {
        final dPass = delta.scenarioPassDeltas[sr.scenario.name];
        final dMrr = delta.scenarioMrrDeltas[sr.scenario.name];
        final dPassStr =
            dPass == null ? 'new' : _fmtDelta(dPass.toDouble());
        final dMrrStr = dMrr == null ? 'new' : _fmtDelta(dMrr);
        buf.writeln(
            '| ${sr.scenario.name} | ${sr.totalQueries} | $passStr | $mrrStr | $dPassStr | $dMrrStr |');
      } else {
        buf.writeln(
            '| ${sr.scenario.name} | ${sr.totalQueries} | $passStr | $mrrStr |');
      }
    }

    // Totals.
    final totalPassStr = '${summary.passedQueries}/${summary.totalQueries}';
    if (delta != null) {
      final dPassDiff =
          (summary.passedQueries - delta.previous.passedQueries).toDouble();
      buf.writeln(
          '| **TOTAL** | **${summary.totalQueries}** | **$totalPassStr** | **${summary.overallMrr.toStringAsFixed(2)}** | **${_fmtDelta(dPassDiff)}** | **${_fmtDelta(delta.mrrDelta)}** |');
    } else {
      buf.writeln(
          '| **TOTAL** | **${summary.totalQueries}** | **$totalPassStr** | **${summary.overallMrr.toStringAsFixed(2)}** |');
    }

    buf.writeln();

    // Per-scenario detail.
    buf.writeln('## Scenario Details');
    buf.writeln();

    for (final sr in summary.scenarioResults) {
      buf.writeln('### ${sr.scenario.name}');
      buf.writeln();
      buf.writeln('> ${sr.scenario.description}');
      buf.writeln();

      for (final qr in sr.queryResults) {
        final icon = qr.pass ? '✅' : '❌';
        buf.writeln('$icon **`${qr.query.query}`** — ${qr.query.description}');
        buf.writeln();

        if (qr.query.expectedTopFragment == kExpectEmpty) {
          buf.writeln(
              'Expected: empty results. Got: ${qr.actual.isEmpty ? "empty ✓" : "${qr.actual.length} results ✗"}');
        } else {
          buf.writeln(
              'Expected `${qr.query.expectedTopFragment}` at rank 1. '
              'Got rank: **${qr.rank == 0 ? "not found" : qr.rank}** '
              '(RR: ${qr.reciprocalRank.toStringAsFixed(2)})');
          buf.writeln();

          if (qr.actual.isNotEmpty) {
            buf.writeln(
                '| Rank | Content (truncated) | Score | FTS | Vec | Entity |');
            buf.writeln('|---|---|---|---|---|---|');
            for (var i = 0; i < qr.actual.length && i < 5; i++) {
              final item = qr.actual[i];
              final content = item.content.length > 60
                  ? '${item.content.substring(0, 57)}...'
                  : item.content;
              buf.writeln(
                  '| ${i + 1} | $content | ${item.score.toStringAsFixed(3)} | ${item.ftsSignal.toStringAsFixed(2)} | ${item.vectorSignal.toStringAsFixed(2)} | ${item.entitySignal.toStringAsFixed(2)} |');
            }
          } else {
            buf.writeln('_No results returned._');
          }
        }
        buf.writeln();
      }
    }

    return buf.toString();
  }

  // ── JSONL ───────────────────────────────────────────────────────────────

  /// Returns a single JSON line for appending to `eval/results.jsonl`.
  String toJsonLine(RunSummary summary) {
    final data = {
      'timestamp': summary.timestamp.toIso8601String(),
      'config': {
        'ftsWeight': summary.config.ftsWeight,
        'vectorWeight': summary.config.vectorWeight,
        'entityWeight': summary.config.entityWeight,
        'relevanceThreshold': summary.config.relevanceThreshold,
        'topK': summary.config.topK,
        'temporalDecayLambda': summary.config.temporalDecayLambda,
        'componentWeights': summary.config.componentWeights,
      },
      'embeddingMode': summary.embeddingMode,
      'overallMrr': summary.overallMrr,
      'overallPassRate': summary.overallPassRate,
      'totalQueries': summary.totalQueries,
      'passedQueries': summary.passedQueries,
      'scenarios': summary.scenarioResults.map((sr) {
        return {
          'name': sr.scenario.name,
          'queries': sr.totalQueries,
          'passed': sr.passedQueries,
          'mrr': sr.mrr,
          'queryDetails': sr.queryResults.map((qr) {
            return {
              'query': qr.query.query,
              'expectedFragment': qr.query.expectedTopFragment,
              'rank': qr.rank,
              'reciprocalRank': qr.reciprocalRank,
              'pass': qr.pass,
              'topContent':
                  qr.actual.isNotEmpty ? qr.actual.first.content : null,
              'topScore':
                  qr.actual.isNotEmpty ? qr.actual.first.score : null,
            };
          }).toList(),
        };
      }).toList(),
    };
    return jsonEncode(data);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static String _configLine(RecallConfig config) {
    final parts = [
      'fts=${config.ftsWeight}',
      'vec=${config.vectorWeight}',
      'entity=${config.entityWeight}',
      'threshold=${config.relevanceThreshold}',
    ];
    if (config.componentWeights.isNotEmpty) {
      final wts = config.componentWeights.entries
          .map((e) => '${e.key}×${e.value}')
          .join(', ');
      parts.add('weights=[$wts]');
    }
    return parts.join('  ');
  }

  static String _fmtTimestamp(DateTime dt) {
    return '${dt.toIso8601String().replaceFirst('T', ' ').substring(0, 19)}Z';
  }

  static String _fmtDelta(double d) {
    if (d > 0.001) return '+${d.toStringAsFixed(3)}';
    if (d < -0.001) return d.toStringAsFixed(3);
    return '=';
  }

  static String _pad(String s, int width) {
    if (s.length >= width) return s.substring(0, width);
    return s.padRight(width);
  }
}
