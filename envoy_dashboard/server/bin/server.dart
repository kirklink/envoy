import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:envoy/envoy.dart';
import 'package:swoop/swoop.dart';

import 'package:envoy_dashboard_server/agent_service.dart';

/// Generic JSON response for ad-hoc maps (avoids boilerplate response classes
/// in an internal dashboard).
class _JsonMap extends JsonResponse {
  final Map<String, dynamic> _data;
  final int _status;

  _JsonMap(this._data, {int status = 200}) : _status = status;

  @override
  int get statusCode => _status;

  @override
  Map<String, dynamic> toJson() => _data;
}

void main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Error: ANTHROPIC_API_KEY environment variable is required.');
    exit(1);
  }

  final config = EnvoyConfig(
    apiKey: apiKey,
    model: Platform.environment['ENVOY_MODEL'] ?? 'claude-sonnet-4-6',
  );

  final workspaceRoot =
      Platform.environment['ENVOY_WORKSPACE'] ?? Directory.current.path;

  final agentService = AgentService(
    config: config,
    workspaceRoot: workspaceRoot,
  );

  final chatClient = anthropic.AnthropicClient(apiKey: apiKey);

  final router = SwoopRouter();

  // POST /api/agent/run — start a new task.
  router.route<Map<String, dynamic>, _JsonMap>(
    method: HttpMethod.post,
    path: '/api/agent/run',
    public: true,
    handler: (ctx, body) async {
      if (body['task'] == null) {
        throw const BadRequest('Missing "task" field.');
      }
      if (agentService.status == AgentStatus.running) {
        throw const Conflict('Agent is already running a task.');
      }

      final task = body['task'] as String;
      final model = body['model'] as String?;

      // Fire and forget — events come via SSE.
      unawaited(agentService.runTask(task, model: model));

      return _JsonMap({'started': true, 'task': task});
    },
  );

  // GET /api/agent/events — SSE stream.
  router.routeNoBody<SseResponse>(
    method: HttpMethod.get,
    path: '/api/agent/events',
    public: true,
    handler: (ctx) async => SseResponse(
      agentService.events.map((event) => SseEvent(
            event: event.type,
            data: jsonEncode(event.toJson()),
          )),
    ),
  );

  // GET /api/agent/status — current agent state.
  router.routeNoBody<_JsonMap>(
    method: HttpMethod.get,
    path: '/api/agent/status',
    public: true,
    handler: (ctx) async => _JsonMap(agentService.toStatusJson()),
  );

  // POST /api/chat/message — simple LLM chat (no agent loop / tools).
  router.route<Map<String, dynamic>, _JsonMap>(
    method: HttpMethod.post,
    path: '/api/chat/message',
    public: true,
    handler: (ctx, body) async {
      if (body['messages'] == null) {
        throw const BadRequest('Missing "messages" field.');
      }

      final rawMessages = body['messages'] as List;
      final model = body['model'] as String? ?? config.model;

      final messages = rawMessages.map((m) {
        final msg = m as Map<String, dynamic>;
        return anthropic.Message(
          role: msg['role'] == 'user'
              ? anthropic.MessageRole.user
              : anthropic.MessageRole.assistant,
          content: anthropic.MessageContent.text(msg['content'] as String),
        );
      }).toList();

      try {
        final response = await chatClient.createMessage(
          request: anthropic.CreateMessageRequest(
            model: anthropic.Model.modelId(model),
            maxTokens: 4096,
            messages: messages,
          ),
        );
        return _JsonMap({
          'response': response.content.text,
          'usage': {
            'input': response.usage?.inputTokens ?? 0,
            'output': response.usage?.outputTokens ?? 0,
          },
        });
      } on anthropic.AnthropicClientException catch (e) {
        throw InternalError('API error ${e.code}: ${e.message}');
      }
    },
  );

  // Note: static file serving (for production builds) not yet added.
  // In dev mode, run the client via `webdev serve web:8084`.

  final server = SwoopServer(
    router,
    config: SwoopConfig(
      port: 8083,
      cors: const CorsConfig(
        allowedOrigins: ['http://localhost:8084'],
        allowedMethods: ['GET', 'POST', 'OPTIONS'],
        allowedHeaders: ['Content-Type'],
      ),
      warnUnguardedRoutes: false,
    ),
  );

  await server.start();
}
