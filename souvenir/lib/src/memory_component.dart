import 'budget.dart';
import 'labeled_recall.dart';
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

/// A pluggable memory component.
///
/// Each component owns its own storage, extraction logic, decay strategy,
/// and recall behavior. Components are fully independent — no cross-component
/// awareness. The engine coordinates them via [consolidate] and [recall].
abstract class MemoryComponent {
  /// Unique name used for budget allocation and recall labeling.
  ///
  /// Must match the key used in [Budget.allocation] and mixer weights.
  String get name;

  /// Called once at engine startup. Initialize storage, load state, etc.
  Future<void> initialize();

  /// Consolidation: episodes are available for extraction.
  ///
  /// The component independently decides what (if anything) to extract
  /// and store. The [llm] callback is provided for components that need
  /// LLM extraction; purely programmatic components may ignore it.
  Future<ConsolidationReport> consolidate(
    List<Episode> episodes,
    LlmCallback llm,
    ComponentBudget budget,
  );

  /// Recall: return items relevant to [query] within [budget].
  ///
  /// Each returned [LabeledRecall] must have [LabeledRecall.componentName]
  /// set to this component's [name].
  Future<List<LabeledRecall>> recall(
    String query,
    ComponentBudget budget,
  );

  /// Cleanup: release resources, close connections.
  Future<void> close();
}
