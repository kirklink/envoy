import 'package:cellar/cellar.dart';

import 'cellar_episode_store.dart';
import 'sqlite_memory_store.dart';

/// Factory for creating Cellar-backed Souvenir stores.
///
/// Manages collection registration, multi-agent prefix isolation, and
/// encryption enforcement. Each agent gets its own set of tables
/// in a shared Cellar database.
///
/// ```dart
/// final cellar = Cellar.open('memory.db', encryptionKey: key);
/// final sc = SouvenirCellar(
///   cellar: cellar,
///   agentId: 'researcher',
///   requireEncryption: true,
/// );
/// final episodeStore = sc.createEpisodeStore();
/// final memoryStore = sc.createMemoryStore();
/// ```
class SouvenirCellar {
  /// The underlying Cellar instance.
  final Cellar cellar;

  /// The collection name prefix (e.g. `'researcher_'` or `''`).
  final String prefix;

  SouvenirCellar._({required this.cellar, required this.prefix});

  /// Creates a SouvenirCellar, registering all collections.
  ///
  /// [agentId] prefixes collection names for multi-agent isolation.
  /// Pass empty string for single-agent mode (no prefix).
  ///
  /// When [requireEncryption] is true, throws [StateError] if the database
  /// is not encrypted via SQLCipher. Always set this to true in production.
  factory SouvenirCellar({
    required Cellar cellar,
    String agentId = '',
    bool requireEncryption = false,
  }) {
    if (requireEncryption) {
      _enforceEncryption(cellar);
    }

    final prefix = agentId.isEmpty ? '' : '${agentId}_';
    final instance = SouvenirCellar._(cellar: cellar, prefix: prefix);
    instance._registerCollections();
    return instance;
  }

  /// Creates a [CellarEpisodeStore] for this agent.
  CellarEpisodeStore createEpisodeStore() {
    return CellarEpisodeStore(cellar, '${prefix}episodes');
  }

  /// Creates a [SqliteMemoryStore] for this agent.
  ///
  /// Uses [cellar.database] directly for raw SQL (FTS5, entity graph,
  /// embeddings). The store manages its own DDL via [initialize].
  SqliteMemoryStore createMemoryStore() {
    return SqliteMemoryStore(cellar.database, prefix: prefix);
  }

  /// Returns the prefixed collection name for a given base name.
  String collectionName(String base) => '$prefix$base';

  void _registerCollections() {
    // Episode store collection (Cellar-managed).
    cellar.registerCollection(episodesCollection(prefix));

    // Memory store uses raw SQL and manages its own DDL via initialize().
    // No Cellar collection registration needed.
  }

  /// Throws [StateError] if the database is not encrypted.
  static void _enforceEncryption(Cellar cellar) {
    try {
      final result = cellar.rawQuery('PRAGMA cipher_version');
      if (result.rows.isEmpty ||
          result.rows.first.values.first == null) {
        throw StateError(
          'Souvenir requires an encrypted database in production. '
          'Pass encryptionKey to Cellar.open().',
        );
      }
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError(
        'Souvenir requires an encrypted database in production. '
        'SQLCipher does not appear to be available.',
      );
    }
  }

  // ── Collection schema definitions ──────────────────────────────────────

  /// Episode collection schema.
  static Collection episodesCollection(String prefix) => Collection(
        name: '${prefix}episodes',
        fields: [
          Field.text('session_id'),
          Field.datetime('timestamp'),
          Field.text('type'),
          Field.text('content', fts: true),
          Field.real('importance', defaultValue: 0.5),
          Field.int('access_count', defaultValue: 0),
          Field.bool('consolidated', defaultValue: false),
          Field.datetime('last_accessed', nullable: true),
        ],
      );
}
