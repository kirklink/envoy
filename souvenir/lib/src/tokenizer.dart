/// Abstract token counter shared across all components.
///
/// The engine owns a single [Tokenizer] instance and passes it through
/// [ComponentBudget]. Components MUST use this rather than implementing
/// their own counting, ensuring consistent budget accounting.
abstract class Tokenizer {
  /// Counts the number of tokens in [text].
  int count(String text);
}

/// Fallback tokenizer: character count / 4, rounded up.
///
/// Acceptable approximation for English text when a model-specific tokenizer
/// is unavailable. Matches v1's `tokenEstimationDivisor = 4.0`.
class ApproximateTokenizer implements Tokenizer {
  const ApproximateTokenizer();

  @override
  int count(String text) => text.isEmpty ? 0 : (text.length / 4).ceil();
}
