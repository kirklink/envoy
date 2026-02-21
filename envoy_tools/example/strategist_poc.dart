// Strategist/Worker PoC: two-agent delegation pattern.
//
// The Strategist plans and delegates. The Worker executes focused tasks
// with a fresh context each time. No tools, no Envoy framework — just
// raw LLM calls to test whether delegation produces better reasoning.
//
// Run with: source ../.env && dart run example/strategist_poc.dart

import 'dart:io';
import 'dart:math' show min;

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

// ── ANSI helpers ─────────────────────────────────────────────────────────

const _kReset = '\x1B[0m';
const _kBold = '\x1B[1m';
const _kDim = '\x1B[2m';
const _kCyan = '\x1B[36m';
const _kGreen = '\x1B[32m';
const _kYellow = '\x1B[33m';
const _kRed = '\x1B[31m';

String _bold(String s) => '$_kBold$s$_kReset';
String _dim(String s) => '$_kDim$s$_kReset';
String _cyan(String s) => '$_kCyan$s$_kReset';
String _green(String s) => '$_kGreen$s$_kReset';
String _yellow(String s) => '$_kYellow$s$_kReset';
String _red(String s) => '$_kRed$s$_kReset';

// ── Safety limits ────────────────────────────────────────────────────────

const _maxIterations = 10;
const _maxTokens = 50000;

// ── System prompts ───────────────────────────────────────────────────────

const _strategistPrompt = '''
You are the Strategist — a thoughtful planner who delegates work to a Worker.

YOUR ROLE:
- Analyze the task and break it into clear, ordered steps.
- Delegate ONE piece of work at a time to the Worker with specific instructions.
- Review the Worker's output against the original requirements.
- If the work doesn't meet requirements, delegate again with corrections.
- Assemble the final deliverable from the Worker's approved outputs.

RULES:
- You NEVER write content yourself — you only plan, delegate, and review.
- Follow the user's instructions PRECISELY — don't change or weaken requirements.
- Be specific in delegations — tell the Worker exactly what to produce.
- Review critically — reject work that doesn't meet the brief.

PROTOCOL:
When you want to delegate work to the Worker, write:
[DELEGATE]
Your specific instructions for the Worker here.
[/DELEGATE]

When you have assembled the final complete deliverable, write:
[DONE]
The complete final output here.
[/DONE]

Any text outside these tags is your thinking (visible to you in later turns,
but not sent to the Worker). Think out loud about your plan and review.
''';

const _workerPrompt = '''
You are the Worker — a skilled writer who receives specific tasks and executes them.

YOUR ROLE:
- Execute the task exactly as described in your instructions.
- Focus only on what's asked — no extra framing or meta-commentary.
- Return your work directly, ready to use.

RULES:
- Follow the instructions precisely.
- Don't add disclaimers, introductions, or "here's what I wrote" wrappers.
- Just deliver the work.
''';

// ── Regex for protocol markers ───────────────────────────────────────────

final _delegateRe = RegExp(r'\[DELEGATE\](.*?)\[/DELEGATE\]', dotAll: true);
final _doneRe = RegExp(r'\[DONE\](.*?)\[/DONE\]', dotAll: true);

// ── Main ─────────────────────────────────────────────────────────────────

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('ERROR: ANTHROPIC_API_KEY not set');
    exit(1);
  }

  final client = anthropic.AnthropicClient(apiKey: apiKey);
  const model = 'claude-haiku-4-5-20251001';

  const task = '''
Write a blog post about why Dart is underrated for server-side development.

Requirements:
- Target audience: Node.js developers considering alternatives
- Exactly 3 sections, each with a clear markdown header (##)
- Each section: 2-3 paragraphs
- Each section MUST include a side-by-side code example comparing Dart and Node.js
- Tone: conversational but technical, not salesy
- Total length: roughly 800-1200 words
''';

  print(_bold('Task:'));
  print('$task\n');

  // ── Strategist conversation ──────────────────────────────────────────

  final messages = <anthropic.Message>[
    anthropic.Message(
      role: anthropic.MessageRole.user,
      content: anthropic.MessageContent.text(task),
    ),
  ];

  var totalTokens = 0;
  var delegations = 0;

  for (var turn = 1; turn <= _maxIterations; turn++) {
    print(_dim('─── Strategist turn $turn ───'));

    final response = await client.createMessage(
      request: anthropic.CreateMessageRequest(
        model: anthropic.Model.modelId(model),
        maxTokens: 4096,
        system: anthropic.CreateMessageRequestSystem.text(_strategistPrompt),
        messages: messages,
      ),
    );

    final usage = response.usage;
    final turnTokens =
        (usage?.inputTokens ?? 0) + (usage?.outputTokens ?? 0);
    totalTokens += turnTokens;
    print(_dim('  tokens: $turnTokens (cumulative: $totalTokens)'));

    final text = response.content.text;

    // Add strategist response to conversation.
    messages.add(anthropic.Message(
      role: anthropic.MessageRole.assistant,
      content: response.content,
    ));

    // ── Check for [DONE] ───────────────────────────────────────────────

    final doneMatch = _doneRe.firstMatch(text);
    if (doneMatch != null) {
      print(_green('\n✓ Strategist delivered final output.\n'));
      print('${'=' * 60}');
      print(doneMatch.group(1)!.trim());
      print('${'=' * 60}');
      _printStats(turn, delegations, totalTokens);
      return;
    }

    // ── Check for [DELEGATE] ───────────────────────────────────────────

    final delegateMatch = _delegateRe.firstMatch(text);
    if (delegateMatch != null) {
      delegations++;
      final workerTask = delegateMatch.group(1)!.trim();

      // Print strategist thinking (text before the tag).
      final thinkingEnd = text.indexOf('[DELEGATE]');
      final thinking = text.substring(0, thinkingEnd).trim();
      if (thinking.isNotEmpty) {
        print(_cyan('  💭 $thinking'));
      }

      final preview = workerTask.substring(0, min(100, workerTask.length));
      print(_yellow('  📋 → Worker: $preview...'));

      // ── Worker call (fresh context) ────────────────────────────────

      final workerResponse = await client.createMessage(
        request: anthropic.CreateMessageRequest(
          model: anthropic.Model.modelId(model),
          maxTokens: 4096,
          system: anthropic.CreateMessageRequestSystem.text(_workerPrompt),
          messages: [
            anthropic.Message(
              role: anthropic.MessageRole.user,
              content: anthropic.MessageContent.text(workerTask),
            ),
          ],
        ),
      );

      final workerUsage = workerResponse.usage;
      final workerTokens =
          (workerUsage?.inputTokens ?? 0) + (workerUsage?.outputTokens ?? 0);
      totalTokens += workerTokens;

      final workerText = workerResponse.content.text;
      print(_green(
          '  ✓ Worker returned ${workerText.length} chars ($workerTokens tokens)'));

      // Feed result back to strategist.
      messages.add(anthropic.Message(
        role: anthropic.MessageRole.user,
        content: anthropic.MessageContent.text(
          'Worker result:\n\n$workerText',
        ),
      ));
    } else {
      // No markers — strategist is thinking but not acting.
      final preview = text.substring(0, min(200, text.length));
      print(_cyan('  💭 $preview${text.length > 200 ? '...' : ''}'));

      messages.add(anthropic.Message(
        role: anthropic.MessageRole.user,
        content: anthropic.MessageContent.text(
          'Continue. Use [DELEGATE] to hand off work or [DONE] when the '
          'final deliverable is assembled.',
        ),
      ));
    }

    // ── Token budget check ─────────────────────────────────────────────

    if (totalTokens >= _maxTokens) {
      print(_red('\n⚠ Token budget exceeded ($totalTokens >= $_maxTokens). '
          'Stopping.'));
      _printStats(turn, delegations, totalTokens);
      return;
    }
  }

  print(_red('\n⚠ Max iterations reached ($_maxIterations). Stopping.'));
  _printStats(_maxIterations, delegations, totalTokens);
}

void _printStats(int turns, int delegations, int tokens) {
  print('\n${_bold('Stats')}: $turns strategist turns, '
      '$delegations delegations, $tokens total tokens');
}
