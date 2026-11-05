part of 'agent_web_reader.dart';

/// Scores readable prose and document structure rather than choosing the
/// longest element. Link-heavy chrome otherwise beats a short real article.
class _WebReadability {
  final Document document;
  final _stats = <Node, _WebTextStats>{};
  _WebReadability(this.document);

  static final _noise = RegExp(
    r'(?:^|[\s_-])(?:nav(?:bar|igation)?|menu|sidebar|related|recommendations?|recommended|share|social|advert(?:isement)?s?|ads?|promo|cookie(?:banner)?|breadcrumbs?|toc|pager|site-header|site-banner)(?:$|[\s_-])',
    caseSensitive: false,
  );
  static final _notes = RegExp(
    r'(?:^|[\s_-])(?:notes?|admonition|alert|callout|warning|tip|footnotes?|references|bibliography)(?:$|[\s_-])',
    caseSensitive: false,
  );

  String _marker(Element node) => '${node.id} ${node.className}';
  bool _protected(Element node) {
    for (Element? item = node; item != null; item = item.parent) {
      if (['pre', 'code', 'table', 'blockquote'].contains(item.localName) ||
          [
            'note',
            'doc-footnote',
            'doc-bibliography',
          ].contains(item.attributes['role']) ||
          _notes.hasMatch(_marker(item))) {
        return true;
      }
    }
    return false;
  }

  void clean() {
    var visibleProse = 0;
    for (final paragraph in document.querySelectorAll('p')) {
      var inFallback = false;
      for (
        Element? parent = paragraph.parent;
        parent != null;
        parent = parent.parent
      ) {
        if ([
              'noscript',
              'nav',
              'footer',
              'aside',
              'form',
            ].contains(parent.localName) ||
            parent.attributes.containsKey('hidden') ||
            parent.attributes['aria-hidden'] == 'true' ||
            _noise.hasMatch(_marker(parent))) {
          inFallback = true;
          break;
        }
      }
      if (!inFallback && paragraph.text.trim().length >= 80) {
        visibleProse += paragraph.text.trim().length;
      }
    }
    for (final node in document.querySelectorAll('noscript')) {
      if (visibleProse >= 160) {
        node.remove();
        continue;
      }
      Element fallback = node;
      if (node.querySelector('p, article, main') == null) {
        fallback = Element.tag('div')
          ..nodes.addAll(html.parseFragment(node.text).nodes.toList());
      }
      if (fallback.querySelector('p, article, main') != null &&
          fallback.text.trim().length >= 160) {
        if (fallback != node) node.replaceWith(fallback);
      } else {
        node.remove();
      }
    }
    for (final node in document.querySelectorAll(
      'script, style, svg, canvas, iframe, form, nav, [role="navigation"], [role="banner"], [hidden], [aria-hidden="true"], .mw-editsection, .noprint',
    )) {
      node.remove();
    }
    for (final node in document.querySelectorAll('*')) {
      final style = node.attributes['style'] ?? '';
      if (RegExp(
        r'(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\b',
        caseSensitive: false,
      ).hasMatch(style)) {
        node.remove();
        continue;
      }
      if (_protected(node)) continue;
      if (['aside', 'footer'].contains(node.localName) ||
          ['complementary', 'dialog'].contains(node.attributes['role']) ||
          ['div', 'section', 'ul', 'ol', 'header'].contains(node.localName) &&
              _noise.hasMatch(_marker(node))) {
        node.remove();
      }
    }
  }

  _WebTextStats stats(Node node) => _stats.putIfAbsent(node, () {
    if (node is Text) {
      final text = node.data.replaceAll(RegExp(r'\s+'), ' ').trim();
      return _WebTextStats(
        text.length,
        0,
        0,
        0,
        RegExp(r'[。！？；，.!?;,]').allMatches(text).length,
        0,
      );
    }
    var chars = 0,
        linked = 0,
        prose = 0,
        blocks = 0,
        punctuation = 0,
        links = 0;
    for (final child in node.nodes) {
      final data = stats(child);
      chars += data.chars;
      linked += data.linked;
      prose += data.prose;
      blocks += data.blocks;
      punctuation += data.punctuation;
      links += data.links;
    }
    if (node is Element) {
      if (node.localName == 'a') {
        linked = chars;
        links++;
      }
      if (node.localName == 'p' && chars >= 40) {
        prose += chars - linked;
        blocks++;
      }
      if (node.localName == 'pre' && chars >= 20) blocks++;
    }
    return _WebTextStats(chars, linked, prose, blocks, punctuation, links);
  });

  Element? select() {
    clean();
    final body = document.body;
    if (body == null) return null;
    final explicit = document
        .querySelectorAll(
          'article, main, [role="main"], #content, .post-content, .entry-content, .article-body, .mw-parser-output, [itemprop="articleBody"]',
        )
        .toSet();
    final candidates = <Element>{body, ...explicit};
    for (final node in document.querySelectorAll('div, section')) {
      final data = stats(node);
      if (data.chars >= 160 && (data.blocks >= 2 || data.punctuation >= 3)) {
        candidates.add(node);
      }
    }
    // A forum consists of several posts. Preserve the common container rather
    // than silently returning just its longest reply.
    final posts = document.querySelectorAll(
      'article.crawler-post, .cooked, [itemprop="articleBody"]',
    );
    Element? postContainer;
    if (posts.length > 1) {
      postContainer = posts.first.parent;
      while (postContainer != null &&
          !posts.every((post) => _contains(postContainer!, post))) {
        postContainer = postContainer.parent;
      }
      if (postContainer != null) candidates.add(postContainer);
    }
    Element root = body;
    var best = -1.0;
    for (final candidate in candidates) {
      final data = stats(candidate);
      if (data.chars == 0) continue;
      var score =
          (data.chars - data.linked) +
          data.prose * .25 +
          data.punctuation.clamp(0, 100) * 4 +
          data.blocks.clamp(0, 30) * 15;
      if (data.linked / data.chars > .6) score *= .25;
      if (candidate == body) score *= .85;
      if (explicit.contains(candidate)) {
        score *= candidate.localName == 'main' ? 1.05 : 1.2;
      }
      if (candidate == postContainer) score *= 1.4;
      if (score > best) {
        best = score;
        root = candidate;
      }
    }
    // Remove unlabelled link rails only when a substantial prose body exists.
    // Keep references, notes, code, tables and the main content of index pages.
    final content = stats(root);
    if (content.chars - content.linked >= 300 || content.prose >= 160) {
      for (final node in root.querySelectorAll('div, section')) {
        if (_protected(node)) continue;
        final data = stats(node);
        if (data.links >= 5 &&
            data.chars > 0 &&
            data.linked / data.chars > .85 &&
            data.chars - data.linked < 80 &&
            data.prose < 80 &&
            node.querySelector('h1, h2, h3, pre, table, blockquote') == null) {
          node.remove();
        }
      }
    }
    return root;
  }

  static bool _contains(Element parent, Element child) {
    for (Element? node = child; node != null; node = node.parent) {
      if (node == parent) return true;
    }
    return false;
  }
}

class _WebTextStats {
  final int chars, linked, prose, blocks, punctuation, links;
  const _WebTextStats(
    this.chars,
    this.linked,
    this.prose,
    this.blocks,
    this.punctuation,
    this.links,
  );
}
