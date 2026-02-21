/// Thin callback for LLM calls during consolidation.
///
/// Accepts a system prompt and user prompt; returns the LLM's text response.
/// Decouples souvenir from any specific LLM SDK.
typedef LlmCallback = Future<String> Function(String system, String user);
