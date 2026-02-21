/// End-to-end validation of Souvenir with a real LLM.
///
/// Exercises the full memory lifecycle: episode recording, LLM-driven
/// consolidation, cross-session recall, personality drift, and procedural
/// memory — all with real Claude API calls.
///
/// Requires: ANTHROPIC_API_KEY environment variable.
///
/// ```bash
/// set -a && source /workspaces/dart/envoy/.env && set +a
/// dart run example/live_test.dart
/// ```
import 'dart:io';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:souvenir/souvenir.dart';

const _model = 'claude-haiku-4-5-20251001';

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final client = anthropic.AnthropicClient(apiKey: apiKey);

  /// LLM callback bridging Souvenir's thin interface to anthropic_sdk_dart.
  Future<String> llm(String system, String user) async {
    final response = await client.createMessage(
      request: anthropic.CreateMessageRequest(
        model: const anthropic.Model.modelId(_model),
        maxTokens: 1024,
        system: anthropic.CreateMessageRequestSystem.text(system),
        messages: [
          anthropic.Message(
            role: anthropic.MessageRole.user,
            content: anthropic.MessageContent.text(user),
          ),
        ],
      ),
    );
    return response.content.text;
  }

  // ── Setup ──────────────────────────────────────────────────────────────

  final souvenir = Souvenir(
    // In-memory database — no file needed for validation.
    config: const SouvenirConfig(
      consolidationMinAge: Duration.zero, // Consolidate immediately.
      flushThreshold: 100, // Manual flush control.
      personalityMinEpisodes: 0, // Update every consolidation (demo only).
    ),
    identityText:
        'A meticulous Dart developer agent that values code quality, '
        'thorough testing, and clean architecture. Prefers composition over '
        'inheritance and small, focused functions.',
    procedures: {
      'debugging': 'When debugging:\n'
          '1. Reproduce the error consistently\n'
          '2. Read the stack trace carefully\n'
          '3. Add targeted logging before guessing\n'
          '4. Check recent changes first',
      'code_review': 'When reviewing code:\n'
          '1. Check for security issues first\n'
          '2. Verify error handling at boundaries\n'
          '3. Look for missing tests\n'
          '4. Assess naming and readability',
    },
  );
  await souvenir.initialize();

  _header('Initial state');
  print('Identity: ${souvenir.identity}');
  print('Personality: ${souvenir.personality}');
  print('');

  // ── Session 1: Backend refactoring ─────────────────────────────────────

  _header('Session 1: Backend refactoring');

  final session1 = [
    Episode(
      sessionId: 'ses_01',
      type: EpisodeType.userDirective,
      content: 'Refactor the authentication module to use JWT instead of '
          'session cookies. The current implementation is in auth_handler.dart.',
    ),
    Episode(
      sessionId: 'ses_01',
      type: EpisodeType.toolResult,
      content: 'Read auth_handler.dart: found 3 endpoints using session-based '
          'auth. Cookie middleware at line 45, session store at line 78. '
          'No tests covering auth flow.',
    ),
    Episode(
      sessionId: 'ses_01',
      type: EpisodeType.decision,
      content: 'Decided to keep backward compatibility by supporting both '
          'session cookies and JWT during migration. New endpoints will use '
          'JWT exclusively. Added jose package for JWT signing/verification.',
    ),
    Episode(
      sessionId: 'ses_01',
      type: EpisodeType.toolResult,
      content: 'Wrote jwt_middleware.dart with RS256 signing, 1-hour expiry, '
          'and refresh token rotation. Added 12 unit tests — all passing.',
    ),
    Episode(
      sessionId: 'ses_01',
      type: EpisodeType.error,
      content: 'JWT verification failed in integration test: clock skew '
          'between test runner and token issuer. Fixed by adding 30-second '
          'leeway to verification.',
    ),
  ];

  for (final ep in session1) {
    await souvenir.record(ep);
    print('  Recorded: [${ep.type.name}] ${_truncate(ep.content, 60)}');
  }
  await souvenir.flush();

  print('\nConsolidating session 1...');
  final r1 = await souvenir.consolidate(llm);
  _printConsolidation(r1);

  print('\nPersonality after session 1:');
  print('  ${souvenir.personality}');

  // ── Session 2: Database optimization ───────────────────────────────────

  _header('Session 2: Database optimization');

  final session2 = [
    Episode(
      sessionId: 'ses_02',
      type: EpisodeType.userDirective,
      content: 'The user list page is loading slowly. Profile and optimize '
          'the database queries.',
    ),
    Episode(
      sessionId: 'ses_02',
      type: EpisodeType.toolResult,
      content: 'Profiled user_repository.dart: the getAllUsers query joins '
          '4 tables with no indexes on foreign keys. Query takes 2.3 seconds '
          'for 10K rows. SQLite EXPLAIN shows full table scan on user_roles.',
    ),
    Episode(
      sessionId: 'ses_02',
      type: EpisodeType.decision,
      content: 'Added composite index on user_roles(user_id, role_id). '
          'Also added pagination with LIMIT/OFFSET instead of loading all '
          'rows. Query time dropped from 2.3s to 45ms for first page.',
    ),
    Episode(
      sessionId: 'ses_02',
      type: EpisodeType.observation,
      content: 'The project uses SQLite for development but PostgreSQL in '
          'production. Need to verify index syntax works on both. The stanza '
          'package handles this abstraction.',
    ),
  ];

  for (final ep in session2) {
    await souvenir.record(ep);
    print('  Recorded: [${ep.type.name}] ${_truncate(ep.content, 60)}');
  }
  await souvenir.flush();

  print('\nConsolidating session 2...');
  final r2 = await souvenir.consolidate(llm);
  _printConsolidation(r2);

  print('\nPersonality after session 2:');
  print('  ${souvenir.personality}');

  // ── Recall: cross-session queries ──────────────────────────────────────

  _header('Cross-session recall');

  for (final query in [
    'JWT authentication',
    'database performance',
    'testing patterns',
    'SQLite',
  ]) {
    final results = await souvenir.recall(query);
    print('Query: "$query" → ${results.length} result(s)');
    for (final r in results) {
      print('  [${r.source.name}] (${r.score.toStringAsFixed(3)}) '
          '${_truncate(r.content, 70)}');
    }
    print('');
  }

  // ── loadContext: session start assembly ────────────────────────────────

  _header('loadContext: "debug the auth module"');

  final ctx = await souvenir.loadContext('debug the auth module');
  print('Memories: ${ctx.memories.length}');
  for (final m in ctx.memories) {
    print('  [imp=${m.importance}] ${_truncate(m.content, 70)}');
  }
  print('Episodes: ${ctx.episodes.length}');
  for (final ep in ctx.episodes) {
    print('  [${ep.type.name}] ${_truncate(ep.content, 60)}');
  }
  print('Personality: ${ctx.personality != null ? "yes" : "null"}');
  print('Identity: ${ctx.identity != null ? "yes" : "null"}');
  print('Procedures: ${ctx.procedures.length}');
  for (final p in ctx.procedures) {
    print('  ${_truncate(p, 60)}');
  }
  print('Estimated tokens: ${ctx.estimatedTokens}');

  // ── Pattern tracking ──────────────────────────────────────────────────

  _header('Pattern tracking');

  await souvenir.recordOutcome(
    taskType: 'debugging',
    success: true,
    sessionId: 'ses_01',
  );
  await souvenir.recordOutcome(
    taskType: 'debugging',
    success: false,
    sessionId: 'ses_02',
    notes: 'Clock skew issue was tricky to diagnose',
  );
  print('Recorded 2 outcomes for "debugging" task type.');

  // ── Final state ───────────────────────────────────────────────────────

  _header('Final state');
  print('Identity (immutable):');
  print('  ${souvenir.identity}');
  print('');
  print('Personality (drifted):');
  print('  ${souvenir.personality}');

  await souvenir.close();
  print('\nDone.');
}

void _header(String title) {
  print('');
  print('${'=' * 70}');
  print(' $title');
  print('${'=' * 70}');
}

void _printConsolidation(ConsolidationResult r) {
  print('  Sessions processed: ${r.sessionsProcessed}');
  print('  Sessions skipped:   ${r.sessionsSkipped}');
  print('  Memories created:   ${r.memoriesCreated}');
  print('  Memories merged:    ${r.memoriesMerged}');
  print('  Entities upserted:  ${r.entitiesUpserted}');
  print('  Relationships:      ${r.relationshipsUpserted}');
  print('  Memories decayed:   ${r.memoriesDecayed}');
  print('  Personality updated: ${r.personalityUpdated}');
}

String _truncate(String s, int max) =>
    s.length > max ? '${s.substring(0, max)}...' : s;
