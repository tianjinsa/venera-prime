/// Accept only ordinary web links; these are displayed, never fetched here.
Uri? agentWebUri(String value, {Uri? base}) {
  if (value.isEmpty ||
      value.length > 4096 ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
    return null;
  }
  final parsed = Uri.tryParse(value);
  if (parsed == null) return null;
  final uri = base == null ? parsed : base.resolveUri(parsed);
  if (!['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

String agentSourceLink(String title, Uri uri) {
  var label = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (label.isEmpty) label = uri.host;
  if (label.length > 100) label = '${label.substring(0, 100)}…';
  label = label.replaceAllMapped(
    RegExp(r'[\\\x60*_\[\]<>]'),
    (m) => '\\${m[0]}',
  );
  final url = uri.toString().replaceAll('<', '%3C').replaceAll('>', '%3E');
  return '[$label](<$url>)';
}

/// Compare sources without fragments or marketing attribution, retaining
/// document parameters such as id, page, language and search terms.
String agentWebIdentity(Uri uri) {
  final parameters = <String, List<String>>{};
  for (final key in uri.queryParametersAll.keys.toList()..sort()) {
    final lower = key.toLowerCase();
    if (lower.startsWith('utm_') ||
        ['gclid', 'fbclid', 'msclkid'].contains(lower)) {
      continue;
    }
    parameters[key] = uri.queryParametersAll[key]!;
  }
  return uri
      .replace(
        fragment: '',
        queryParameters: parameters.isEmpty ? null : parameters,
        query: parameters.isEmpty ? '' : null,
      )
      .toString();
}
