import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_web_reader.dart';
import 'package:venera/agent/agent_models.dart';

String extract(String body) =>
    AgentWebReader.extract(
          body,
          Uri.parse('https://example.org/posts/story'),
        )['markdown']
        as String;
final prose = List.filled(
  5,
  '正文讲述漫画阅读器的设计，保留章节、作者和阅读进度。遇到图片加载问题时，可以检查来源与网络状态。',
).join();
String links(String label) => List.generate(
  12,
  (i) => '<a href="/navigation/$i">$label 导航链接$i</a>',
).join();

void main() {
  test('a small labelled teaser cannot replace the full article', () {
    final md = extract(
      '<div class="entry-content">登录后查看摘要</div><article><h1>真正的文章</h1><p>$prose</p><p>文章结尾必须保留。</p></article>',
    );
    expect(md, contains('# 真正的文章'));
    expect(md, contains('文章结尾必须保留'));
    expect(md, isNot(contains('登录后查看摘要')));
  });

  test(
    'removes boilerplate and dense link rails without losing article prose',
    () {
      final md = extract(
        '''<main><div class="sidebar">${links('侧栏')}</div>
      <article><h1>文章标题</h1><p>$prose</p><div>${links('无关菜单')}</div>
      <div class="related-posts">相关推荐</div><div class="cookie-banner">Cookie consent</div>
      <p style="display: none !important">隐藏广告</p><p>最后一段正文</p></article></main>''',
      );
      expect(md, contains(prose));
      expect(md, contains('最后一段正文'));
      for (final noise in ['侧栏', '无关菜单', '相关推荐', 'Cookie consent', '隐藏广告']) {
        expect(md, isNot(contains(noise)), reason: noise);
      }
    },
  );

  test(
    'preserves documentation notes, definitions, citations and code spacing',
    () {
      final refs = List.generate(
        6,
        (i) => '<li><a href="/source/$i">参考文献$i</a></li>',
      ).join();
      final md = extract(
        '''<main><h1>文档</h1><p>$prose</p>
      <aside role="note">重要的版本兼容说明</aside><dl><dt>章节</dt><dd>按顺序组织的漫画内容。</dd></dl>
      <pre><code class="language-python">if ready:
    first()



    second()</code></pre><footer role="doc-bibliography" class="references"><h2>引用</h2><ol>$refs</ol></footer></main>''',
      );
      expect(md, contains('重要的版本兼容说明'));
      expect(md, contains('**章节**'));
      expect(md, contains('按顺序组织的漫画内容'));
      expect(md, contains('first()\n\n\n\n    second()'));
      expect(md, contains('参考文献5'));
    },
  );

  test('forum extraction keeps every post instead of only the longest', () {
    final md = extract('''<div id="topic"><h1>讨论主题</h1>
      <article class="crawler-post"><h2>作者甲</h2><div itemprop="articleBody"><p>$prose</p></div></article>
      <article class="crawler-post"><h2>作者乙</h2><div itemprop="articleBody"><p>第二条回复也必须保留，不能因为比主帖短就丢弃。</p></div></article>
      </div>''');
    expect(md, contains('作者甲'));
    expect(md, contains('作者乙'));
    expect(md, contains('第二条回复也必须保留'));
  });

  test(
    'uses a substantial static noscript fallback, excluding enable-JS notices',
    () {
      final md = extract(
        '<div id="app"></div><footer><p>$prose</p></footer><noscript><article><h1>静态正文</h1><p>$prose</p></article></noscript>',
      );
      expect(md, contains('静态正文'));
      expect(md, contains(prose));
    },
  );

  test('a static fallback does not duplicate a visible article', () {
    final md = extract(
      '<article><h1>已渲染正文</h1><p>$prose</p></article><noscript><article><p>$prose</p></article></noscript>',
    );
    expect('已渲染正文'.allMatches(md), hasLength(1));
    expect(prose.allMatches(md), hasLength(1));
  });

  test('articles about browser verification are still readable documents', () {
    final md = extract(
      '<article><h1>Browser verification</h1><p>The phrase verify you are human is part of this explanation, not a challenge form.</p></article>',
    );
    expect(md, contains('verify you are human'));
  });

  test('a verification notice in main is not an article', () {
    expect(
      () => extract(
        '<main><p>Please verify you are human before continuing.</p></main>',
      ),
      throwsA(
        isA<AgentException>().having((e) => e.code, 'code', 'WEB_BLOCKED'),
      ),
    );
  });

  test('nested table cells are not emitted a second time as outer rows', () {
    final md = extract(
      '<article><table><tr><th>Outer</th></tr><tr><td>Detail<table><tr><th>Inner</th></tr><tr><td>Unique nested cell</td></tr></table></td></tr></table></article>',
    );
    expect('Unique nested cell'.allMatches(md), hasLength(1));
  });

  test('index documents keep their actual lists of links', () {
    final md = extract(
      '<main><h1>文档索引</h1><ul><li>${links('有效索引')}</li></ul></main>',
    );
    expect(md, contains('有效索引'));
    expect(md, contains('/navigation/11'));
  });

  test('generic paragraph containers outrank a long unlabelled menu', () {
    final md = extract(
      '<div>${links('站点入口')}</div><div><h1>无语义标签的正文</h1><p>$prose</p><p>第二个段落，讨论具体的使用方法和结果。</p></div>',
    );
    expect(md, contains('无语义标签的正文'));
    expect(md, isNot(contains('站点入口')));
  });

  test('honours safe base links and rejects unsafe bases', () {
    expect(
      extract(
        '<head><base href="https://docs.example.org/manual/"></head><article><a href="chapter">正文链接</a></article>',
      ),
      contains('https://docs.example.org/manual/chapter'),
    );
    expect(
      extract(
        '<head><base href="file:///private/"></head><article><a href="chapter">正文链接</a></article>',
      ),
      contains('https://example.org/posts/chapter'),
    );
  });
}
