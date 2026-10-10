import 'agent_models.dart';
import 'agent_web_links.dart';

/// Display-only markup. Provider output, especially Anthropic encrypted
/// citations and result blocks, is retained separately and replayed unchanged.
String? agentResponsesCitedText(List<AgentJson> items) {
  final output = StringBuffer();
  var found = false;
  for (final item in items) {
    if (item['type'] != 'message') continue;
    for (final part in item['content'] as List? ?? const []) {
      if (part is! Map) continue;
      var text = part['text'] as String? ?? part['refusal'] as String? ?? '';
      final insertions = <int, List<String>>{};
      final seen = <String>{};
      for (final citation in part['annotations'] as List? ?? const []) {
        if (citation is! Map || citation['type'] != 'url_citation') continue;
        final uri = agentWebUri(citation['url'] as String? ?? '');
        if (uri == null) continue;
        final end = _textOffset(text, citation['end_index']);
        if (!seen.add('$end:$uri')) continue;
        found = true;
        final link = agentSourceLink(citation['title'] as String? ?? '', uri);
        (insertions[end] ??= []).add(link);
      }
      // Insert from the end so earlier offsets are unchanged. Never replace
      // cited facts: an annotation may cover a sentence, not a citation marker.
      for (final offset
          in insertions.keys.toList()..sort((a, b) => b.compareTo(a))) {
        text = text.replaceRange(
          offset,
          offset,
          ' ${insertions[offset]!.join(' ')}',
        );
      }
      if (insertions.isNotEmpty) {
        text = text.replaceAll(RegExp(r'cite[^]*'), '');
      }
      output.write(text);
    }
  }
  return found ? output.toString() : null;
}

int _textOffset(String text, Object? index) {
  if (index is! int || index < 0) return text.length;
  // API character offsets count Unicode code points; Dart strings use UTF-16.
  var characters = 0;
  var offset = 0;
  for (final rune in text.runes) {
    if (characters++ == index) return offset;
    offset += rune > 0xffff ? 2 : 1;
  }
  return text.length;
}

String? agentMessagesCitedText(List<AgentJson> blocks) {
  final output = StringBuffer();
  var found = false;
  for (final block in blocks) {
    if (block['type'] != 'text') continue;
    output.write(block['text'] as String? ?? '');
    final seen = <String>{};
    for (final citation in block['citations'] as List? ?? const []) {
      if (citation is! Map ||
          citation['type'] != 'web_search_result_location') {
        continue;
      }
      final uri = agentWebUri(citation['url'] as String? ?? '');
      if (uri == null || !seen.add(uri.toString())) continue;
      output.write(
        ' ${agentSourceLink(citation['title'] as String? ?? '', uri)}',
      );
      found = true;
    }
  }
  return found ? output.toString() : null;
}

List<AgentJson> agentResponsesSearches(List<AgentJson> items) => [
  for (final item in items)
    if (item['type'] == 'web_search_call')
      {
        'type': 'native_search',
        'id': item['id'],
        'state': switch (item['status']) {
          'completed' => 'done',
          'failed' => 'failed',
          _ => 'pending',
        },
        'text': _actionDescription(item['action']),
      },
];

String _actionDescription(Object? value) {
  if (value is! Map) return '模型服务执行了网页搜索';
  if (value['type'] == 'open_page') return '读取网页：${value['url'] ?? ''}';
  if (value['type'] == 'find_in_page') {
    return '在网页中查找：${value['pattern'] ?? ''}';
  }
  final queries = value['queries'];
  return queries is List
      ? '搜索：${queries.whereType<String>().join('；')}'
      : '搜索：${value['query'] ?? '由模型服务选择关键词'}';
}

List<AgentJson> agentMessagesSearches(List<AgentJson> blocks) {
  final searches = <AgentJson>[];
  final queries = <String, String>{};
  final completed = <String>{};
  for (final block in blocks) {
    if (block['type'] == 'server_tool_use' && block['name'] == 'web_search') {
      final input = block['input'];
      queries[block['id'] as String? ?? ''] = input is Map
          ? input['query'] as String? ?? ''
          : '';
    }
  }
  for (final block in blocks) {
    if (block['type'] != 'web_search_tool_result') continue;
    final id = block['tool_use_id'] as String? ?? '';
    completed.add(id);
    final content = block['content'];
    final error = content is Map ? content['error_code'] : null;
    searches.add({
      'type': 'native_search',
      'id': id,
      'state': content is List ? 'done' : 'failed',
      'text': [
        if ((queries[id] ?? '').isNotEmpty) '搜索：${queries[id]}',
        if (content is List) '模型服务返回 ${content.length} 条网页结果',
        if (error != null) '搜索未完成：$error',
      ].join('\n'),
    });
  }
  for (final query in queries.entries.where(
    (e) => !completed.contains(e.key),
  )) {
    searches.add({
      'type': 'native_search',
      'id': query.key,
      'state': 'pending',
      'text': '等待模型服务继续搜索：${query.value}',
    });
  }
  return searches;
}
