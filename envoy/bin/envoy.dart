import 'dart:io';

import 'package:args/args.dart';
import 'package:envoy/envoy.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('model',
        abbr: 'm',
        defaultsTo: 'claude-opus-4-6',
        help: 'Anthropic model ID')
    ..addOption('max-tokens',
        defaultsTo: '8192', help: 'Token budget for context and response')
    ..addOption('max-iterations',
        defaultsTo: '20', help: 'Max agent loop iterations before giving up')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  late ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error: $e');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (parsed['help'] as bool || parsed.rest.isEmpty) {
    stdout.writeln('Usage: dart run envoy [options] <task>');
    stdout.writeln(parser.usage);
    exit(parsed['help'] as bool ? 0 : 1);
  }

  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY environment variable is not set');
    exit(1);
  }

  final config = EnvoyConfig(
    apiKey: apiKey,
    model: parsed['model'] as String,
    maxTokens: int.parse(parsed['max-tokens'] as String),
    maxIterations: int.parse(parsed['max-iterations'] as String),
  );

  final agent = EnvoyAgent(config);
  final task = parsed.rest.join(' ');

  try {
    final result = await agent.run(task);
    stdout.writeln(result.response);
    if (result.outcome == RunOutcome.maxIterations) {
      stderr.writeln('Warning: hit max iterations (${result.iterations})');
    }
    stderr.writeln(result);
  } on Exception catch (e) {
    stderr.writeln('Error: $e');
    exit(1);
  }
}
