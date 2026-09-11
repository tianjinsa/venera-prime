import 'agent_models.dart';

/// Token counts for one response, never the sum of repeated conversation turns.
/// Input includes cached tokens; cached is a breakdown, not an extra charge.
class AgentUsage {
  final int? inputTokens;
  final int? cachedTokens;
  final int? outputTokens;
  final int totalTokens;
  const AgentUsage({
    this.inputTokens,
    this.cachedTokens,
    this.outputTokens,
    required this.totalTokens,
  });

  static AgentUsage? fromResponse(Object? value) {
    if (value is! Map) return null;
    int? count(Object? value) =>
        value is num &&
            value.isFinite &&
            value >= 0 &&
            value == value.truncateToDouble()
        ? value.toInt()
        : null;
    int? detail(String key, String field) =>
        value[key] is Map ? count(value[key][field]) : null;
    var input = count(value['prompt_tokens']);
    var cached =
        detail('prompt_tokens_details', 'cached_tokens') ??
        detail('input_tokens_details', 'cached_tokens') ??
        count(value['prompt_cache_hit_tokens']) ??
        count(value['cached_tokens']);
    if (input == null) {
      input = count(value['input_tokens']);
      if (input != null) {
        // These top-level cache fields are separate from input_tokens in
        // Anthropic-style usage. Nested cached_tokens is already included.
        final read = count(value['cache_read_input_tokens']);
        final created = count(value['cache_creation_input_tokens']);
        input += (read ?? 0) + (created ?? 0);
        cached ??= read;
      } else {
        final hit = count(value['prompt_cache_hit_tokens']);
        final miss = count(value['prompt_cache_miss_tokens']);
        if (hit != null && miss != null) input = hit + miss;
      }
    }
    final output =
        count(value['completion_tokens']) ?? count(value['output_tokens']);
    final total =
        count(value['total_tokens']) ??
        (input != null && output != null ? input + output : null);
    if (total == null) return null;
    return AgentUsage(
      inputTokens: input,
      cachedTokens: cached,
      outputTokens: output,
      totalTokens: total,
    );
  }

  AgentJson toJson() => {
    if (inputTokens != null) 'input_tokens': inputTokens,
    if (cachedTokens != null) 'cached_tokens': cachedTokens,
    if (outputTokens != null) 'output_tokens': outputTokens,
    'total_tokens': totalTokens,
  };
}

/// This replaces only the wire history. Original messages and tool receipts
/// remain in the message table for display, recovery, and audit.
class AgentConversationContext {
  final String summary;
  final String? throughMessageId;
  final AgentUsage? usage;
  final String? usageModelId;
  final int? compactedAt;
  final int compactionCount;
  const AgentConversationContext({
    this.summary = '',
    this.throughMessageId,
    this.usage,
    this.usageModelId,
    this.compactedAt,
    this.compactionCount = 0,
  });
  bool get hasSummary => summary.isNotEmpty && throughMessageId != null;

  AgentConversationContext withUsage(AgentUsage? next, String modelId) =>
      AgentConversationContext(
        summary: summary,
        throughMessageId: throughMessageId,
        usage: next,
        usageModelId: modelId,
        compactedAt: compactedAt,
        compactionCount: compactionCount,
      );
}
