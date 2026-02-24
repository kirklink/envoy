import 'llm_callback.dart';
import 'models/episode.dart';

/// Report of what a component did during consolidation.
///
/// Returned by [MemoryComponent.consolidate]. The engine logs these
/// for observability and future tuning.
class ConsolidationReport {
  /// Name of the component that produced this report.
  final String componentName;

  /// Number of new items created in storage.
  final int itemsCreated;

  /// Number of existing items merged with new information.
  final int itemsMerged;

  /// Number of items that decayed below threshold and were removed or
  /// marked inactive.
  final int itemsDecayed;

  /// Number of episodes this component consumed (extracted from).
  ///
  /// A component is not obligated to consume any episodes. Multiple
  /// components may consume the same episode.
  final int episodesConsumed;

  const ConsolidationReport({
    required this.componentName,
    this.itemsCreated = 0,
    this.itemsMerged = 0,
    this.itemsDecayed = 0,
    this.episodesConsumed = 0,
  });
}

/// A pluggable memory component (v3 — consolidation only).
///
/// Components write to a shared [MemoryStore] during consolidation.
/// Recall is handled by the engine's unified recall pipeline —
/// components do not implement recall.
abstract class MemoryComponent {
  /// Unique name used as the `component` field on stored memories.
  String get name;

  /// Called once at engine startup.
  Future<void> initialize();

  /// Consolidation: extract and store memories from episodes.
  ///
  /// The component writes to the shared store (provided at construction)
  /// with [StoredMemory.component] set to this component's [name].
  /// The [llm] callback is provided for components that need LLM
  /// extraction; purely programmatic components may ignore it.
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
  );

  /// Cleanup: release resources, close connections.
  Future<void> close();
}
