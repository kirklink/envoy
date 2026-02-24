import 'dart:math' as math;

import 'budget.dart';
import 'labeled_recall.dart';

/// Budget usage report for a single component.
class BudgetUsage {
  /// Name of the component.
  final String componentName;

  /// Tokens allocated to this component.
  final int allocated;

  /// Tokens actually used by this component's selected items.
  final int used;

  /// Whether the component exceeded its allocation.
  bool get overBudget => used > allocated;

  const BudgetUsage({
    required this.componentName,
    required this.allocated,
    required this.used,
  });
}

/// Result of mixing recall items from all components.
class MixResult {
  /// Ranked, budget-trimmed recall items.
  final List<LabeledRecall> items;

  /// Per-component budget usage report.
  final Map<String, BudgetUsage> componentUsage;

  /// Total tokens consumed by the items in [items].
  final int totalTokensUsed;

  const MixResult({
    required this.items,
    required this.componentUsage,
    required this.totalTokensUsed,
  });
}

/// Abstract mixer: takes labeled recalls from all components and produces
/// a ranked, budget-trimmed result.
///
/// The mixer does not enforce component budgets (that is each component's
/// responsibility). It normalizes scores across heterogeneous component
/// scales and reports per-component budget usage.
abstract class Mixer {
  /// Mix recall items from all components into a unified ranking.
  MixResult mix(
    Map<String, List<LabeledRecall>> componentRecalls,
    Budget budget,
  );
}

/// Default mixer: per-component normalization + weighted score rebalancing.
///
/// Each component's scores are first normalized to [0, 1] by dividing by the
/// component's maximum score. This makes scores comparable across components
/// that use fundamentally different scoring scales (e.g. Jaccard vs RRF).
/// Weights then control how much each component contributes to the final
/// ranking. Sorts by adjusted score descending, then takes items until the
/// total token budget is exhausted.
class WeightedMixer implements Mixer {
  /// Per-component weight multipliers. Components not listed default to 1.0.
  final Map<String, double> weights;

  const WeightedMixer({this.weights = const {}});

  @override
  MixResult mix(
    Map<String, List<LabeledRecall>> componentRecalls,
    Budget budget,
  ) {
    // 1. Normalize per-component scores to [0, 1], then apply weights.
    //    Normalization ensures that RRF-based components (scores ~0.01-0.05)
    //    compete fairly with Jaccard-based ones (scores ~0.05-1.0).
    final weighted = <_WeightedItem>[];
    for (final entry in componentRecalls.entries) {
      final componentWeight = weights[entry.key] ?? 1.0;
      final items = entry.value;
      final maxScore = items.isEmpty
          ? 0.0
          : items.map((r) => r.score).reduce(math.max);
      for (final recall in items) {
        final normalizedScore = maxScore > 0 ? recall.score / maxScore : 0.0;
        weighted.add(_WeightedItem(
          recall: recall,
          adjustedScore: normalizedScore * componentWeight,
        ));
      }
    }

    // 2. Sort by adjusted score descending.
    weighted.sort((a, b) => b.adjustedScore.compareTo(a.adjustedScore));

    // 3. Take items until total budget exhausted.
    final selected = <LabeledRecall>[];
    var totalUsed = 0;
    for (final item in weighted) {
      final tokens = budget.tokenizer.count(item.recall.content);
      if (totalUsed + tokens > budget.totalTokens && selected.isNotEmpty) {
        break; // Budget exceeded, but always include at least one item.
      }
      selected.add(item.recall);
      totalUsed += tokens;
    }

    // 4. Build per-component usage report from selected items.
    final perComponentUsed = <String, int>{};
    for (final item in selected) {
      final tokens = budget.tokenizer.count(item.content);
      perComponentUsed[item.componentName] =
          (perComponentUsed[item.componentName] ?? 0) + tokens;
    }

    final usage = <String, BudgetUsage>{};
    for (final name in componentRecalls.keys) {
      usage[name] = BudgetUsage(
        componentName: name,
        allocated: budget.allocation[name] ?? 0,
        used: perComponentUsed[name] ?? 0,
      );
    }

    return MixResult(
      items: selected,
      componentUsage: usage,
      totalTokensUsed: totalUsed,
    );
  }
}

class _WeightedItem {
  final LabeledRecall recall;
  final double adjustedScore;

  const _WeightedItem({required this.recall, required this.adjustedScore});
}
