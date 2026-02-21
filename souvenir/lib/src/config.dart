/// Configuration for the souvenir memory system.
///
/// All scoring, tuning, and threshold constants live here — one place
/// to find every lever that affects memory system behavior.
class SouvenirConfig {
  // ── Write pipeline ───────────────────────────────────────────────────────

  /// Number of episodes buffered in working memory before auto-flush.
  final int flushThreshold;

  // ── Episodic importance defaults ─────────────────────────────────────────
  //
  // Default importance values per EpisodeType. Applied when an Episode is
  // created without an explicit importance value.

  /// Default importance for [EpisodeType.userDirective] episodes.
  final double importanceUserDirective;

  /// Default importance for [EpisodeType.error] episodes.
  final double importanceError;

  /// Default importance for [EpisodeType.toolResult] episodes.
  final double importanceToolResult;

  /// Default importance for [EpisodeType.decision] episodes.
  final double importanceDecision;

  /// Default importance for [EpisodeType.conversation] episodes.
  final double importanceConversation;

  /// Default importance for [EpisodeType.observation] episodes.
  final double importanceObservation;

  // ── Consolidation ────────────────────────────────────────────────────────

  /// Minimum age of an episode before it is eligible for consolidation.
  final Duration consolidationMinAge;

  /// BM25 score threshold for merging a new fact into an existing memory.
  final double mergeThreshold;

  /// Fallback importance when the LLM does not specify one during extraction.
  final double defaultImportance;

  /// Fallback confidence when the LLM does not specify one during extraction.
  final double defaultConfidence;

  // ── Importance decay ─────────────────────────────────────────────────────

  /// Decay multiplier applied to memories not accessed within [decayInactivePeriod].
  final double importanceDecayRate;

  /// Memories not accessed within this period have their importance decayed.
  final Duration decayInactivePeriod;

  // ── Retrieval pipeline ───────────────────────────────────────────────────

  /// Default number of results returned by [Souvenir.recall].
  final int recallTopK;

  /// Reciprocal Rank Fusion constant (k). Higher values flatten the score
  /// distribution across ranks; lower values favor top-ranked items more.
  final int rrfK;

  /// Lambda for temporal decay: `score * e^(-lambda * age_days)`.
  ///
  /// Higher values penalize older items more aggressively.
  final double temporalDecayLambda;

  /// Maximum token budget for session context assembly via [Souvenir.loadContext].
  final int contextTokenBudget;

  /// Estimated characters per token for token budget calculations.
  ///
  /// The heuristic `chars / divisor` gives ~80% accuracy for English text.
  final double tokenEstimationDivisor;

  // ── Embeddings ──────────────────────────────────────────────────────────

  /// Number of vector similarity candidates to consider before RRF fusion.
  ///
  /// Only used when an [EmbeddingProvider] is available.
  final int embeddingTopK;

  // ── Personality ────────────────────────────────────────────────────────

  /// Minimum cosine distance between old and new personality text before an
  /// update is applied. Range 0.0–1.0; lower = more sensitive to change.
  ///
  /// Only enforced when an [EmbeddingProvider] is available. Without
  /// embeddings, every LLM-suggested personality update is applied.
  final double minPersonalityDrift;

  // ── Procedures ─────────────────────────────────────────────────────────

  /// Maximum token budget for procedure injection in [Souvenir.loadContext].
  ///
  /// Prevents procedures from consuming the entire context window. Uses the
  /// same chars/divisor heuristic as [contextTokenBudget].
  final int maxProcedureTokens;

  const SouvenirConfig({
    // Write pipeline.
    this.flushThreshold = 50,
    // Episodic importance defaults.
    this.importanceUserDirective = 0.95,
    this.importanceError = 0.8,
    this.importanceToolResult = 0.8,
    this.importanceDecision = 0.75,
    this.importanceConversation = 0.4,
    this.importanceObservation = 0.3,
    // Consolidation.
    this.consolidationMinAge = const Duration(minutes: 5),
    this.mergeThreshold = 0.5,
    this.defaultImportance = 0.5,
    this.defaultConfidence = 1.0,
    // Importance decay.
    this.importanceDecayRate = 0.95,
    this.decayInactivePeriod = const Duration(days: 30),
    // Retrieval pipeline.
    this.recallTopK = 10,
    this.rrfK = 60,
    this.temporalDecayLambda = 0.01,
    this.contextTokenBudget = 4000,
    this.tokenEstimationDivisor = 4.0,
    // Embeddings.
    this.embeddingTopK = 20,
    // Personality.
    this.minPersonalityDrift = 0.1,
    // Procedures.
    this.maxProcedureTokens = 2000,
  });

  /// Returns the default importance for the given [episodeType] name.
  double importanceForEpisodeType(String episodeType) {
    return switch (episodeType) {
      'userDirective' => importanceUserDirective,
      'error' => importanceError,
      'toolResult' => importanceToolResult,
      'decision' => importanceDecision,
      'conversation' => importanceConversation,
      'observation' => importanceObservation,
      _ => defaultImportance,
    };
  }
}
