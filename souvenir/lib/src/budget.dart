import 'tokenizer.dart';

/// Top-level token budget with per-component allocation.
///
/// Owned by the [Souvenir] engine. Each component receives a
/// [ComponentBudget] view of its allocation via [forComponent].
class Budget {
  /// Total token budget across all components.
  final int totalTokens;

  /// Per-component token allocation. Keys are component names.
  final Map<String, int> allocation;

  /// Shared tokenizer for consistent counting.
  final Tokenizer tokenizer;

  const Budget({
    required this.totalTokens,
    required this.allocation,
    required this.tokenizer,
  });

  /// Returns a [ComponentBudget] for the named component.
  ///
  /// If [name] is not in [allocation], the component receives zero tokens.
  /// This is intentional — unrecognized components get no budget rather
  /// than silently consuming shared resources.
  ComponentBudget forComponent(String name) {
    return ComponentBudget(
      allocatedTokens: allocation[name] ?? 0,
      tokenizer: tokenizer,
    );
  }
}

/// A single component's view of its token budget.
///
/// Tracks consumption via [consume]. Components call [consume] with each
/// piece of content they intend to include in recall results.
class ComponentBudget {
  /// Maximum tokens allocated to this component.
  final int allocatedTokens;

  /// Shared tokenizer reference.
  final Tokenizer tokenizer;

  int _usedTokens = 0;

  ComponentBudget({
    required this.allocatedTokens,
    required this.tokenizer,
  });

  /// Tokens consumed so far.
  int get usedTokens => _usedTokens;

  /// Tokens remaining before budget is exhausted. Can be negative.
  int get remainingTokens => allocatedTokens - _usedTokens;

  /// Whether the component has exceeded its allocation.
  bool get isOverBudget => _usedTokens > allocatedTokens;

  /// Counts tokens in [text] using the shared tokenizer and records
  /// the consumption.
  ///
  /// Returns the token count for the given text. Does NOT prevent
  /// over-budget consumption — components are trusted to check
  /// [remainingTokens] before calling this.
  int consume(String text) {
    final tokens = tokenizer.count(text);
    _usedTokens += tokens;
    return tokens;
  }
}
