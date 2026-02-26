import 'dart:math' as math;

/// Cosine similarity between two vectors.
///
/// Returns a value in [0, 1] for normalized vectors. Returns 0.0 if vectors
/// are empty, have mismatched dimensions, or either has zero magnitude.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  final denom = na * nb;
  if (denom <= 0) return 0;
  return dot / math.sqrt(denom);
}
