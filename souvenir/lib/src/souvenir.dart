import 'dart:convert';

import 'package:stanza_sqlite/stanza_sqlite.dart';

import 'config.dart';
import 'consolidation.dart';
import 'embedding_provider.dart';
import 'llm_callback.dart';
import 'models/episode.dart';
import 'models/memory.dart';
import 'models/recall.dart';
import 'models/session_context.dart';
import 'personality.dart';
import 'retrieval.dart';
import 'store/souvenir_store.dart';

/// Persistent, human-modeled memory system for autonomous agents.
///
/// ```dart
/// final souvenir = Souvenir(dbPath: 'memory.db');
/// await souvenir.initialize();
///
/// await souvenir.record(Episode(
///   sessionId: 'ses_01',
///   type: EpisodeType.toolResult,
///   content: 'File analysis completed successfully',
/// ));
///
/// final results = await souvenir.recall('file analysis');
/// ```
class Souvenir {
  final String? _dbPath;
  final SouvenirConfig _config;
  final EmbeddingProvider? _embeddings;
  final String? _identityText;

  StanzaSqlite? _db;
  SouvenirStore? _store;
  PersonalityManager? _personality;
  final List<Episode> _buffer = [];

  /// Creates a souvenir instance backed by a SQLite database at [dbPath].
  ///
  /// Pass `null` for [dbPath] to use an in-memory database (useful for tests).
  /// Pass an [EmbeddingProvider] to enable vector similarity search in recall
  /// and automatic embedding generation during consolidation.
  /// Pass [identityText] to enable the personality system — immutable core
  /// identity + mutable personality that drifts with consolidation.
  Souvenir({
    String? dbPath,
    SouvenirConfig config = const SouvenirConfig(),
    EmbeddingProvider? embeddings,
    String? identityText,
  })  : _dbPath = dbPath,
        _config = config,
        _embeddings = embeddings,
        _identityText = identityText;

  /// Opens the database and creates tables. Idempotent — safe on every startup.
  Future<void> initialize() async {
    _db = _dbPath != null
        ? StanzaSqlite.open(_dbPath!)
        : StanzaSqlite.memory();
    _store = SouvenirStore(_db!);
    await _store!.initialize();

    // Initialize personality system.
    _personality = PersonalityManager(
      _store!,
      identityText: _identityText,
      config: _config,
      embeddings: _embeddings,
    );
    await _personality!.initialize();
  }

  /// Flushes the buffer and closes the database.
  Future<void> close() async {
    await flush();
    _db = null;
    _store = null;
  }

  /// Records an episode to working memory.
  ///
  /// The episode is buffered in-process and flushed to SQLite when the buffer
  /// exceeds [SouvenirConfig.flushThreshold], or when [flush] / [close] is
  /// called explicitly.
  Future<void> record(Episode episode) async {
    _buffer.add(episode);
    if (_buffer.length >= _config.flushThreshold) {
      await flush();
    }
  }

  /// Flushes all buffered episodes to SQLite.
  ///
  /// No-op if the buffer is empty.
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    _requireInitialized();

    final batch = List<Episode>.of(_buffer);
    _buffer.clear();
    await _store!.insertEpisodes(batch);
  }

  /// Searches memory using multi-signal retrieval with RRF fusion.
  ///
  /// Queries episodic memory (BM25), semantic memory (BM25), vector similarity
  /// (when an [EmbeddingProvider] is available), and the entity knowledge
  /// graph. Results are fused via Reciprocal Rank Fusion and adjusted by
  /// temporal decay, importance, and access frequency.
  Future<List<Recall>> recall(
    String query, {
    RecallOptions? options,
  }) async {
    _requireInitialized();
    final opts = options ?? RecallOptions(topK: _config.recallTopK);
    return RetrievalPipeline(_store!, _config, _embeddings).run(query, opts);
  }

  /// Assembles a [SessionContext] for the start of a new agent session.
  ///
  /// Runs a token-budgeted recall for relevant memories, fetches recent
  /// episodes, and includes personality/identity/procedures when available
  /// (Phase 5+).
  Future<SessionContext> loadContext(String sessionIntent) async {
    _requireInitialized();

    // Recall relevant memories with token budget (semantic only).
    final memoryRecalls = await recall(
      sessionIntent,
      options: RecallOptions(
        topK: _config.recallTopK,
        tokenBudget: _config.contextTokenBudget,
        includeEpisodic: false,
        includeSemantic: true,
      ),
    );

    // Hydrate full Memory objects from recall results.
    final memoryIds = memoryRecalls.map((r) => r.id).toList();
    final memoryEntities = await _store!.findMemoriesByIds(memoryIds);
    final memories = memoryEntities
        .map((e) => Memory(
              id: e.id,
              content: e.content,
              entityIds: e.entityIds != null
                  ? (jsonDecode(e.entityIds!) as List).cast<String>()
                  : [],
              importance: e.importance,
              createdAt: e.createdAt,
              updatedAt: e.updatedAt,
              sourceEpisodeIds: e.sourceIds != null
                  ? (jsonDecode(e.sourceIds!) as List).cast<String>()
                  : [],
              accessCount: e.accessCount,
              lastAccessed: e.lastAccessed,
            ))
        .toList();

    // Recent episodes: today + yesterday.
    final recentEntities = await _store!.recentEpisodes(limit: 50);
    final cutoff = DateTime.now().subtract(const Duration(days: 2));
    final episodes = recentEntities
        .where((e) => e.timestamp.isAfter(cutoff))
        .map((e) => Episode(
              id: e.id,
              sessionId: e.sessionId,
              timestamp: e.timestamp,
              type: EpisodeType.values.firstWhere((t) => t.name == e.type),
              content: e.content,
              importance: e.importance,
              accessCount: e.accessCount,
              lastAccessed: e.lastAccessed,
              consolidated: e.consolidated == 1,
            ))
        .toList();

    return SessionContext(
      memories: memories,
      episodes: episodes,
      personality: _personality?.personality,
      identity: _personality?.identity,
    );
  }

  /// Consolidates unconsolidated episodes into semantic memories.
  ///
  /// Requires an [LlmCallback] for fact extraction. Passed per-call because
  /// the agent may not always have an LLM available. When an
  /// [EmbeddingProvider] was given at construction, embeddings are generated
  /// for each new or merged memory.
  Future<ConsolidationResult> consolidate(LlmCallback llm) async {
    _requireInitialized();
    await flush();
    return ConsolidationPipeline(
      _store!, llm, _config, _embeddings, _personality,
    ).run();
  }

  /// The immutable core identity text, or null if not configured.
  String? get identity => _personality?.identity;

  /// The current personality text, or null if not configured.
  String? get personality => _personality?.personality;

  /// Resets personality to a previous state.
  ///
  /// See [ResetLevel] for available reset modes.
  Future<void> resetPersonality(
    ResetLevel level, {
    LlmCallback? llm,
    DateTime? date,
  }) async {
    _requireInitialized();
    if (_personality == null) {
      throw StateError('Personality system not configured.');
    }
    await _personality!.reset(level, llm: llm, date: date);
  }

  /// Number of episodes currently buffered in working memory.
  int get bufferSize => _buffer.length;

  void _requireInitialized() {
    if (_store == null) {
      throw StateError('Souvenir not initialized. Call initialize() first.');
    }
  }
}
