import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:swoop/ui.dart';
import 'package:web/web.dart' as web;

// In dev mode, the server runs on a different port.
// In production (served from Swoop), use relative paths.
const _apiBase = 'http://localhost:8083';

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class DashboardController {
  // --- Signals ---
  final status = signal<String>('idle');
  final taskInput = signal('');
  final model = signal('claude-sonnet-4-6');
  final toolCalls = signal(<Map<String, dynamic>>[]);
  final logEntries = signal(<LogEntry>[]);
  final response = signal<String?>(null);
  final iterations = signal(0);
  final tokenUsage =
      signal(<String, int>{'input': 0, 'output': 0, 'total': 0});

  // --- Computed ---
  late final statusColor = computed(
    () => status.value == 'running' ? BadgeColor.green : BadgeColor.gray,
  );
  late final statusLabel = computed(
    () => status.value == 'running' ? 'Running' : 'Idle',
  );
  late final isRunning = computed(() => status.value == 'running');
  late final toolCallCount = computed(() => toolCalls.value.length);

  web.EventSource? _eventSource;

  DashboardController() {
    _connectSSE();
  }

  void _connectSSE() {
    _eventSource?.close();
    _eventSource = web.EventSource('$_apiBase/api/agent/events');

    _on('agent_started', (data) {
      status.value = 'running';
      response.value = null;
      _log('Task started: ${data['task']}');
    });

    _on('agent_tool_call_started', (data) {
      toolCalls.value = [
        ...toolCalls.value,
        {
          'tool': data['toolName'],
          'input': _truncate(_formatInput(data['input']), 80),
          'status': 'running',
          'duration': '\u2014', // em dash
        },
      ];
      _log('Tool: ${data['toolName']}');
      if (data['reasoning'] != null) {
        _log('Reasoning: ${_truncate(data['reasoning'] as String, 120)}');
      }
    });

    _on('agent_tool_call_completed', (data) {
      final updated = [...toolCalls.value];
      // Find the last matching running tool call and update it.
      for (var i = updated.length - 1; i >= 0; i--) {
        if (updated[i]['tool'] == data['toolName'] &&
            updated[i]['status'] == 'running') {
          updated[i] = {
            ...updated[i],
            'status': data['success'] == true ? 'done' : 'error',
            'duration': '${data['durationMs']}ms',
          };
          break;
        }
      }
      toolCalls.value = updated;
      final level =
          data['success'] == true ? LogLevel.success : LogLevel.error;
      _log('${data['toolName']} \u2192 ${data['durationMs']}ms', level: level);
    });

    _on('agent_message_added', (data) {
      _log('[${data['role']}] ${_truncate(data['preview'] as String, 100)}');
    });

    _on('agent_completed', (data) {
      status.value = 'idle';
      response.value = data['response'] as String?;
      iterations.value = data['iterations'] as int? ?? 0;
      final tu = data['tokenUsage'] as Map<String, dynamic>?;
      tokenUsage.value = {
        'input': tu?['input'] as int? ?? 0,
        'output': tu?['output'] as int? ?? 0,
        'total': tu?['total'] as int? ?? 0,
      };
      final outcome = data['outcome'] as String? ?? 'unknown';
      _log(
        'Task $outcome (${data['iterations']}i, ${data['durationMs']}ms)',
        level: outcome == 'completed' ? LogLevel.success : LogLevel.warning,
      );
    });

    _on('agent_error', (data) {
      status.value = 'idle';
      _log('Error: ${data['message']}', level: LogLevel.error);
    });
  }

  /// Listens for a named SSE event and parses JSON data.
  void _on(String eventType, void Function(Map<String, dynamic>) handler) {
    _eventSource!.addEventListener(
      eventType,
      ((web.MessageEvent e) {
        final data =
            jsonDecode((e.data as JSString).toDart) as Map<String, dynamic>;
        handler(data);
      }).toJS,
    );
  }

  void _log(String message, {LogLevel level = LogLevel.info}) {
    logEntries.value = [...logEntries.value, LogEntry(message, level: level)];
  }

  static String _truncate(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}...' : s;

  static String _formatInput(Object? input) {
    if (input is Map) return jsonEncode(input);
    if (input is String) return input;
    return input.toString();
  }

  Future<void> run() async {
    if (isRunning.value || taskInput.value.trim().isEmpty) return;

    final task = taskInput.value.trim();
    _log('Sending task: $task');

    // Reset state for new run.
    toolCalls.value = [];
    response.value = null;
    iterations.value = 0;
    tokenUsage.value = {'input': 0, 'output': 0, 'total': 0};

    try {
      final resp = await web.window
          .fetch(
            '$_apiBase/api/agent/run'.toJS,
            web.RequestInit(
              method: 'POST',
              headers: web.Headers()..append('Content-Type', 'application/json'),
              body: jsonEncode({'task': task, 'model': model.value}).toJS,
            ),
          )
          .toDart;

      if (!resp.ok) {
        final body = (await resp.text().toDart).toDart;
        _log('Failed to start task: $body', level: LogLevel.error);
      }
    } catch (e) {
      _log('Network error: $e', level: LogLevel.error);
    }
  }

  void reset() {
    taskInput.value = '';
    toolCalls.value = [];
    logEntries.value = [];
    response.value = null;
    iterations.value = 0;
    tokenUsage.value = {'input': 0, 'output': 0, 'total': 0};
  }
}

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------

web.HTMLElement dashboardPage(DashboardController ctrl) {
  return stack(children: [
    // Status row
    grid(columns: 3, children: [
      card(children: [
        stat(
          label: 'Status',
          value: reactiveBadge(
            content: () => ctrl.statusLabel.value,
            color: () => ctrl.statusColor.value,
          ),
        ),
      ]),
      card(children: [
        stat(
          label: 'Tokens',
          value: text(() => ctrl.tokenUsage.value['total'].toString()),
          description: 'input + output',
        ),
      ]),
      card(children: [
        stat(
          label: 'Tool calls',
          value: text(() => ctrl.toolCallCount.value.toString()),
        ),
      ]),
    ]),

    // Task input
    card(title: 'New Task', children: [
      stack(gap: 'gap-3', children: [
        formField(
          label: 'Task',
          inputNode: input(
            value: ctrl.taskInput,
            placeholder: 'Describe what you want the agent to do...',
          ),
        ),
        formField(
          label: 'Model',
          inputNode: selectInput(
            value: ctrl.model,
            options: [
              ('claude-sonnet-4-6', 'Claude Sonnet 4.6'),
              ('claude-opus-4-6', 'Claude Opus 4.6'),
              ('claude-haiku-4-5-20251001', 'Claude Haiku 4.5'),
            ],
          ),
        ),
        row(gap: 'gap-2', children: [
          btn('Run Agent', onClick: () => ctrl.run()),
          btn('Reset', variant: ButtonVariant.secondary, onClick: ctrl.reset),
        ]),
      ]),
    ]),

    // Tool calls table
    card(title: 'Tool Calls', children: [
      table<Map<String, dynamic>>(
        columns: [
          TableColumn(
            header: 'Tool',
            cell: (r) => r['tool'] as String,
            sortable: true,
            sortValue: (r) => r['tool'] as String,
          ),
          TableColumn(header: 'Input', cell: (r) => r['input'] as String),
          TableColumn(header: 'Duration', cell: (r) => r['duration'] as String),
          TableColumn(
            header: 'Status',
            cell: (r) => r['status'] as String,
            sortable: true,
            sortValue: (r) => r['status'] as String,
          ),
        ],
        rows: ctrl.toolCalls,
        emptyMessage: 'No tool calls yet. Run a task to get started.',
      ),
    ]),

    // Agent response (shown when complete)
    _responseCard(ctrl),
  ]);
}

/// Shows the response card only when a response exists.
web.HTMLElement _responseCard(DashboardController ctrl) {
  final container = div();
  final dispose = effect(() {
    container.innerHTML = ''.toJS;
    if (ctrl.response.value != null && ctrl.response.value!.isNotEmpty) {
      container.appendChild(card(
        title: 'Agent Response',
        children: [
          pre(ctrl.response.value!, className: 'whitespace-pre-wrap text-sm'),
          keyValue(entries: [
            ('Iterations', text(() => ctrl.iterations.value.toString())),
            ('Input tokens',
                text(() => ctrl.tokenUsage.value['input'].toString())),
            ('Output tokens',
                text(() => ctrl.tokenUsage.value['output'].toString())),
          ]),
        ],
      ));
    }
  });
  onRemove(container, dispose);
  return container;
}

web.HTMLElement logsPage(DashboardController ctrl) {
  return stack(children: [
    alert(
      message: 'Logs update in real time via SSE as the agent runs.',
      variant: AlertVariant.info,
    ),
    card(title: 'Agent Log', children: [
      log(entries: ctrl.logEntries, maxHeight: 500),
    ]),
  ]);
}

// ---------------------------------------------------------------------------
// Chat page
// ---------------------------------------------------------------------------

web.HTMLElement chatPage(DashboardController ctrl) {
  final messages = signal(<ChatMessage>[]);
  final sending = signal(false);
  var nextId = 1;

  /// Builds the conversation history for the API (excludes system messages).
  List<Map<String, String>> _buildHistory() {
    return messages.value
        .where((m) => m.role != ChatRole.system)
        .map((m) => {
              'role': m.role == ChatRole.user ? 'user' : 'assistant',
              'content': m.content is String ? m.content as String : '',
            })
        .toList();
  }

  Future<void> sendMessage(String text) async {
    // Add user message.
    messages.value = [
      ...messages.value,
      ChatMessage(id: '${nextId++}', role: ChatRole.user, content: text),
    ];

    sending.value = true;

    try {
      final history = _buildHistory();
      final resp = await web.window
          .fetch(
            '$_apiBase/api/chat/message'.toJS,
            web.RequestInit(
              method: 'POST',
              headers: web.Headers()
                ..append('Content-Type', 'application/json'),
              body: jsonEncode({
                'messages': history,
                'model': ctrl.model.value,
              }).toJS,
            ),
          )
          .toDart;

      if (resp.ok) {
        final body =
            jsonDecode((await resp.text().toDart).toDart) as Map<String, dynamic>;
        final responseText = body['response'] as String;

        // Stream the response token by token for a natural feel.
        final controller = StreamController<String>();
        final id = '${nextId++}';
        messages.value = [
          ...messages.value,
          ChatMessage(
            id: id,
            role: ChatRole.assistant,
            content: streamText(
              controller.stream,
              onDone: () => sending.value = false,
            ),
          ),
        ];

        final words = responseText.split(' ');
        var i = 0;
        Timer.periodic(const Duration(milliseconds: 30), (t) {
          if (i < words.length) {
            controller.add(i == 0 ? words[i] : ' ${words[i]}');
            i++;
          } else {
            t.cancel();
            controller.close();
          }
        });
      } else {
        final body = (await resp.text().toDart).toDart;
        messages.value = [
          ...messages.value,
          ChatMessage(
            id: '${nextId++}',
            role: ChatRole.system,
            content: 'Error: $body',
          ),
        ];
        sending.value = false;
      }
    } catch (e) {
      messages.value = [
        ...messages.value,
        ChatMessage(
          id: '${nextId++}',
          role: ChatRole.system,
          content: 'Network error: $e',
        ),
      ];
      sending.value = false;
    }
  }

  return stack(className: 'h-full', children: [
    row(gap: 'gap-3', className: 'items-center', children: [
      label('Model',
          className: 'text-sm font-medium text-gray-600 dark:text-gray-400'),
      div(className: 'w-64', children: [
        selectInput(
          value: ctrl.model,
          options: [
            ('claude-sonnet-4-6', 'Claude Sonnet 4.6'),
            ('claude-opus-4-6', 'Claude Opus 4.6'),
            ('claude-haiku-4-5-20251001', 'Claude Haiku 4.5'),
          ],
        ),
      ]),
    ]),
    div(
      className: 'flex-1 min-h-0',
      children: [
        chat(
          messages: messages,
          sending: sending,
          placeholder: 'Chat with Claude...',
          showTimestamps: true,
          onSend: sendMessage,
          className: 'h-full rounded-lg border border-gray-200 dark:border-gray-700 '
              'bg-white dark:bg-gray-900',
        ),
      ],
    ),
  ]);
}

// ---------------------------------------------------------------------------
// Dark mode toggle
// ---------------------------------------------------------------------------

web.HTMLElement _darkModeToggle() {
  final container = div(
    className: 'cursor-pointer text-gray-600 dark:text-gray-400 '
        'hover:text-gray-900 dark:hover:text-gray-100',
  );
  final sunIcon = icon(AppIcon.sun, size: 'h-5 w-5');
  final moonIcon = icon(AppIcon.moon, size: 'h-5 w-5');

  void update() {
    container.textContent = '';
    container.appendChild(darkMode.value ? sunIcon : moonIcon);
  }

  update();
  final dispose = effect(() {
    darkMode.value; // track
    update();
  });
  onRemove(container, dispose);
  container.addEventListener('click', ((web.Event _) => toggleDarkMode()).toJS);
  return container;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

void main() {
  initTheme();
  initBreakpoints();
  final ctrl = DashboardController();
  final app = web.document.getElementById('app')!;

  app.appendChild(appShell(
    brand: 'Envoy Dashboard',
    navActions: [_darkModeToggle()],
    sidebar: stack(gap: 'gap-1', children: [
      label('Navigation',
          className:
              'text-xs uppercase tracking-wide text-gray-400 dark:text-gray-500 mb-2'),
      link('Dashboard', href: '/'),
      link('Chat', href: '/chat'),
      link('Logs', href: '/logs'),
      divider(className: 'my-3'),
      label('Agent',
          className:
              'text-xs uppercase tracking-wide text-gray-400 dark:text-gray-500 mb-2'),
      div(children: [
        reactiveBadge(
          content: () => ctrl.statusLabel.value,
          color: () => ctrl.statusColor.value,
        ),
      ]),
    ]),
    content: router(routes: [
      AppRoute('/', (_, __) => dashboardPage(ctrl)),
      AppRoute('/chat', (_, __) => chatPage(ctrl)),
      AppRoute('/logs', (_, __) => logsPage(ctrl)),
    ]),
  ));
}
