import 'package:cellar/cellar.dart';

import 'cellar_episode_store.dart';
import 'durable/durable_memory_store.dart';
import 'environmental/cellar_environmental_memory_store.dart';
import 'task/cellar_task_memory_store.dart';

/// Factory for creating Cellar-backed Souvenir stores.
///
/// Manages collection registration, multi-agent prefix isolation, and
/// encryption enforcement. Each agent gets its own set of collections
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
/// final durableStore = sc.createDurableStore();
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

  /// Creates a [CellarTaskMemoryStore] for this agent.
  CellarTaskMemoryStore createTaskStore() {
    return CellarTaskMemoryStore(cellar, '${prefix}task_items');
  }

  /// Creates a [CellarEnvironmentalMemoryStore] for this agent.
  CellarEnvironmentalMemoryStore createEnvironmentalStore() {
    return CellarEnvironmentalMemoryStore(
      cellar,
      '${prefix}environmental_items',
    );
  }

  /// Creates a [DurableMemoryStore] for this agent.
  ///
  /// Uses [cellar.database] directly for raw SQL (multi-table, entity graph,
  /// embeddings). The durable tables are still registered as Cellar
  /// collections for DDL and auto-migration.
  DurableMemoryStore createDurableStore() {
    return DurableMemoryStore(cellar.database, prefix: prefix);
  }

  /// Returns the prefixed collection name for a given base name.
  String collectionName(String base) => '$prefix$base';

  void _registerCollections() {
    // Episode store collection.
    cellar.registerCollection(episodesCollection(prefix));

    // Task memory collection.
    cellar.registerCollection(taskItemsCollection(prefix));

    // Environmental memory collection.
    cellar.registerCollection(environmentalItemsCollection(prefix));

    // Durable memory uses raw SQL but we register the collections
    // so Cellar manages DDL and migration. The DurableMemoryStore
    // handles its own DDL via initialize(), so we skip these for now
    // to avoid conflicts. The raw tables are created by
    // DurableMemoryStore.initialize().
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

  /// Task items collection schema.
  static Collection taskItemsCollection(String prefix) => Collection(
        name: '${prefix}task_items',
        fields: [
          Field.text('content', fts: true),
          Field.text('category'),
          Field.real('importance', defaultValue: 0.6),
          Field.text('session_id'),
          Field.json('source_episode_ids'),
          Field.datetime('last_accessed', nullable: true),
          Field.int('access_count', defaultValue: 0),
          Field.text('status', defaultValue: 'active'),
          Field.datetime('invalid_at', nullable: true),
        ],
      );

  /// Environmental items collection schema.
  static Collection environmentalItemsCollection(String prefix) => Collection(
        name: '${prefix}environmental_items',
        fields: [
          Field.text('content', fts: true),
          Field.text('category'),
          Field.real('importance', defaultValue: 0.6),
          Field.json('source_episode_ids'),
          Field.datetime('last_accessed', nullable: true),
          Field.int('access_count', defaultValue: 0),
          Field.text('status', defaultValue: 'active'),
        ],
      );
}
