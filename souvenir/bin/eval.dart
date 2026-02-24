/// Souvenir recall evaluation CLI.
///
/// Runs all built-in [EvalScenario]s against a [RecallConfig] you specify via
/// flags, scores them, prints a summary table with deltas vs the previous run,
/// appends a JSON record to `eval/results.jsonl`, and writes a human-readable
/// report to `eval/latest.md`.
///
/// Usage:
/// ```
/// dart run bin/eval.dart                          # default config, fake embeddings
/// dart run bin/eval.dart --vec-weight 2.0         # adjust vector weight
/// dart run bin/eval.dart --ollama                 # use real Ollama embeddings
/// dart run bin/eval.dart --ollama --ollama-model nomic-embed-text
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:souvenir/src/eval/report.dart';
import 'package:souvenir/src/eval/runner.dart';
import 'package:souvenir/src/eval/scenarios.dart';
import 'package:souvenir/src/eval/types.dart';
import 'package:souvenir/src/ollama_embedding_provider.dart';
import 'package:souvenir/src/recall.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('fts-weight',
        abbr: 'f',
        defaultsTo: '1.0',
        help: 'FTS BM25 signal weight')
    ..addOption('vec-weight',
        abbr: 'v',
        defaultsTo: '1.5',
        help: 'Vector cosine signal weight')
    ..addOption('entity-weight',
        abbr: 'e',
        defaultsTo: '0.8',
        help: 'Entity graph signal weight')
    ..addOption('threshold',
        abbr: 't',
        defaultsTo: '0.05',
        help: 'Minimum relevance score to include in results')
    ..addOption('decay',
        defaultsTo: '0.005',
        help: 'Temporal decay lambda (higher = faster decay with age)')
    ..addFlag('ollama',
        defaultsTo: false,
        negatable: false,
        help: 'Use Ollama embeddings instead of fake keyword-cluster embeddings')
    ..addOption('ollama-model',
        defaultsTo: 'all-minilm',
        help: 'Ollama model name (all-minilm=384, nomic-embed-text=768)')
    ..addOption('ollama-host',
        defaultsTo: 'http://localhost:11434',
        help: 'Ollama base URL')
    ..addOption('ollama-dims',
        help: 'Embedding dimensions (auto-detected for all-minilm/nomic-embed-text)')
    ..addFlag('help',
        abbr: 'h',
        negatable: false,
        help: 'Show this help');

  late ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error: $e');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (parsed['help'] as bool) {
    print('dart run bin/eval.dart [options]\n');
    print(parser.usage);
    return;
  }

  // Build RecallConfig from flags.
  final config = RecallConfig(
    ftsWeight: double.parse(parsed['fts-weight'] as String),
    vectorWeight: double.parse(parsed['vec-weight'] as String),
    entityWeight: double.parse(parsed['entity-weight'] as String),
    relevanceThreshold: double.parse(parsed['threshold'] as String),
    temporalDecayLambda: double.parse(parsed['decay'] as String),
  );

  // Set up embedding provider.
  final useOllama = parsed['ollama'] as bool;
  String embeddingMode;
  OllamaEmbeddingProvider? embeddings;

  if (useOllama) {
    final model = parsed['ollama-model'] as String;
    final host = parsed['ollama-host'] as String;
    final dimsStr = parsed['ollama-dims'] as String?;
    final dims = dimsStr != null
        ? int.parse(dimsStr)
        : _defaultDimensions(model);
    embeddingMode = 'ollama:$model';
    embeddings = OllamaEmbeddingProvider(
      model: model,
      dimensions: dims,
      baseUrl: host,
    );
  } else {
    embeddingMode = 'fake (keyword-cluster)';
  }

  // Load previous run for delta comparison.
  final resultsFile = File('eval/results.jsonl');
  RunSummary? previousRun;
  if (resultsFile.existsSync()) {
    final lines = resultsFile
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isNotEmpty) {
      try {
        previousRun = _parsePreviousRun(lines.last);
      } catch (_) {
        // Ignore malformed previous record — delta will just be omitted.
      }
    }
  }

  // Run evaluation.
  print('Running Souvenir recall evaluation...');
  if (useOllama) {
    print('Embeddings: $embeddingMode (host: ${parsed['ollama-host']})');
  }
  print('');

  final runner = EvalRunner(config: config, embeddings: embeddings);

  late RunSummary summary;
  try {
    summary = await runner.runAll(defaultScenarios, embeddingMode: embeddingMode);
  } catch (e) {
    stderr.writeln('Eval failed: $e');
    exit(1);
  }

  // Print console summary.
  final report = EvalReport();
  print(report.toConsole(summary, previous: previousRun));

  // Ensure eval/ directory exists.
  Directory('eval').createSync(recursive: true);

  // Append to JSONL results.
  resultsFile.writeAsStringSync(
    '${report.toJsonLine(summary)}\n',
    mode: FileMode.append,
  );

  // Overwrite latest.md.
  File('eval/latest.md').writeAsStringSync(
    report.toMarkdown(summary, previous: previousRun),
  );

  print('Results → ${resultsFile.path}');
  print('Report  → eval/latest.md');
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Default embedding dimensions for known Ollama models.
int _defaultDimensions(String model) {
  const known = {
    'all-minilm': 384,
    'nomic-embed-text': 768,
    'mxbai-embed-large': 1024,
    'bge-m3': 1024,
  };
  return known[model] ?? 384;
}

// ── Previous-run loading ─────────────────────────────────────────────────────

/// Reconstructs a minimal [RunSummary] from a JSONL line for delta display.
///
/// Only the fields used by [RunDelta] are populated.
RunSummary _parsePreviousRun(String line) {
  final json = jsonDecode(line) as Map<String, dynamic>;

  final configJson = json['config'] as Map<String, dynamic>;
  final config = RecallConfig(
    ftsWeight: (configJson['ftsWeight'] as num).toDouble(),
    vectorWeight: (configJson['vectorWeight'] as num).toDouble(),
    entityWeight: (configJson['entityWeight'] as num).toDouble(),
    relevanceThreshold: (configJson['relevanceThreshold'] as num).toDouble(),
    temporalDecayLambda: (configJson['temporalDecayLambda'] as num).toDouble(),
  );

  final scenariosJson = json['scenarios'] as List<dynamic>;
  final scenarioResults = scenariosJson.map((s) {
    final sMap = s as Map<String, dynamic>;
    final name = sMap['name'] as String;
    final queryDetails = sMap['queryDetails'] as List<dynamic>;

    final queryResults = queryDetails.map((q) {
      final qMap = q as Map<String, dynamic>;
      return QueryResult(
        query: EvalQuery(
          query: qMap['query'] as String,
          expectedTopFragment: (qMap['expectedFragment'] as String?) ?? '',
          description: '',
        ),
        pass: qMap['pass'] as bool,
        rank: (qMap['rank'] as num).toInt(),
        reciprocalRank: (qMap['reciprocalRank'] as num).toDouble(),
        actual: const [],
      );
    }).toList();

    final stub = EvalScenario(
      name: name,
      description: '',
      setup: (_, __) async {},
      queries: queryResults.map((qr) => qr.query).toList(),
    );
    return ScenarioResult(scenario: stub, queryResults: queryResults);
  }).toList();

  return RunSummary(
    timestamp: DateTime.parse(json['timestamp'] as String),
    config: config,
    embeddingMode: (json['embeddingMode'] as String?) ?? 'unknown',
    scenarioResults: scenarioResults,
  );
}
