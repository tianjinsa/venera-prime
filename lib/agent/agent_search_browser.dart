import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/proxy.dart';

import 'agent_models.dart';

bool agentSearchNavigationAllowed(Uri uri, AgentSearchEngine engine) {
  final domain = switch (engine) {
    AgentSearchEngine.bing => 'bing.com',
    AgentSearchEngine.google => 'google.com',
    AgentSearchEngine.tavily => 'api.tavily.com',
    AgentSearchEngine.deepseek => 'api.deepseek.com',
  };
  return uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      (uri.host == domain || uri.host.endsWith('.$domain'));
}

Future<void> _browserQueue = Future.value();

/// Use the existing WebView only when the HTTP page needs JavaScript.
/// Serialize temporary instances so searches do not retain several renderers.
Future<String> loadAgentSearchPage(Uri url, AgentRun run) async {
  if (Platform.isLinux) {
    throw const AgentException(
      'SEARCH_BROWSER_UNAVAILABLE',
      '当前平台无法在后台渲染此搜索页面，请改用 Bing、Tavily 或 DeepSeek',
    );
  }
  final engine = url.host == 'www.google.com'
      ? AgentSearchEngine.google
      : AgentSearchEngine.bing;
  if (!agentSearchNavigationAllowed(url, engine) || url.path != '/search') {
    throw const AgentException('SEARCH_REDIRECT', '只允许加载搜索引擎的搜索页面');
  }
  final previous = _browserQueue;
  final released = Completer<void>();
  _browserQueue = previous.then((_) => released.future);
  try {
    await run.wait(previous);
    run.check();
    return await _loadPage(url, engine, run);
  } finally {
    released.complete();
  }
}

Future<String> _loadPage(
  Uri url,
  AgentSearchEngine engine,
  AgentRun run,
) async {
  HeadlessInAppWebView? browser;
  WebViewEnvironment? environment;
  InAppWebViewController? controller;
  AgentException? pageError;
  var finished = false;
  var loaded = false;

  Future<void> disposeBrowser() async {
    try {
      await browser?.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {
      // The platform may already have released the view.
    }
  }

  Future<String> load() async {
    final configuredProxy = appdata.settings['proxy']?.toString() ?? 'system';
    if (Platform.isAndroid) {
      final supported = await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
      run.check();
      if (finished) throw const AgentException('CANCELLED', '已停止搜索');
      if (configuredProxy == 'system') {
        if (supported) await ProxyController.instance().clearProxyOverride();
      } else {
        if (!supported) {
          throw const AgentException(
            'SEARCH_PROXY_UNSUPPORTED',
            '此设备的网页组件不支持应用代理，请改用 Bing、Tavily 或 DeepSeek',
          );
        }
        final proxy = await getProxy();
        if (proxy != null && Uri.parse(proxy).userInfo.isNotEmpty) {
          throw const AgentException(
            'SEARCH_PROXY_UNSUPPORTED',
            '网页搜索暂不支持需要认证的代理，请改用 Bing、Tavily 或 DeepSeek',
          );
        }
        run.check();
        if (finished) throw const AgentException('CANCELLED', '已停止搜索');
        await ProxyController.instance().setProxyOverride(
          settings: ProxySettings(
            proxyRules: [ProxyRule(url: proxy ?? 'direct://')],
          ),
        );
      }
    }
    if (Platform.isWindows) {
      final proxy = await getProxy();
      if (proxy != null && Uri.parse(proxy).userInfo.isNotEmpty) {
        throw const AgentException(
          'SEARCH_PROXY_UNSUPPORTED',
          '网页搜索暂不支持需要认证的代理，请改用 Bing、Tavily 或 DeepSeek',
        );
      }
      final created = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: '${App.cachePath}/agent_search_webview',
          additionalBrowserArguments: proxy != null
              ? '--proxy-server=$proxy'
              : configuredProxy == 'direct'
              ? '--no-proxy-server'
              : null,
        ),
      );
      environment = created;
      if (finished) {
        await created.dispose();
        throw const AgentException('CANCELLED', '已停止搜索');
      }
    }
    run.check();
    if (finished) throw const AgentException('CANCELLED', '已停止搜索');
    browser = HeadlessInAppWebView(
      webViewEnvironment: environment,
      initialSize: const Size(1024, 768),
      initialUrlRequest: URLRequest(url: WebUri(url.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        useShouldOverrideUrlLoading: true,
        mediaPlaybackRequiresUserGesture: true,
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        geolocationEnabled: false,
        thirdPartyCookiesEnabled: false,
        isInspectable: false,
      ),
      onWebViewCreated: (value) => controller = value,
      onLoadStart: (_, _) => loaded = false,
      onLoadStop: (_, _) => loaded = true,
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      ),
      onGeolocationPermissionsShowPrompt: (_, origin) async =>
          GeolocationPermissionShowPromptResponse(
            origin: origin,
            allow: false,
            retain: false,
          ),
      shouldOverrideUrlLoading: (_, action) async {
        if (finished || run.isCancelled) return NavigationActionPolicy.CANCEL;
        final next = Uri.tryParse(action.request.url?.toString() ?? '');
        if (next == null || !agentSearchNavigationAllowed(next, engine)) {
          if (action.isForMainFrame) {
            pageError = const AgentException('SEARCH_REDIRECT', '搜索页面跳转到了其他网站');
          }
          return NavigationActionPolicy.CANCEL;
        }
        if (next.path.startsWith('/sorry') ||
            next.host.startsWith('consent.')) {
          pageError = AgentException(
            'SEARCH_BLOCKED',
            '${engine.label} 需要网页验证，请改用其他已启用的引擎',
          );
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onReceivedError: (_, request, error) {
        // WebView2 cancels the first navigation while awaiting the asynchronous
        // navigation policy, then reissues it. That is not a network failure.
        if (request.isForMainFrame == true &&
            error.type != WebResourceErrorType.CANCELLED) {
          pageError ??= AgentException(
            'SEARCH_REQUEST_FAILED',
            '搜索页面加载失败（${error.type}），请检查网络或改用其他引擎',
          );
        }
      },
      onReceivedHttpError: (_, request, response) {
        if (request.isForMainFrame == true &&
            (response.statusCode ?? 0) >= 400) {
          pageError ??= AgentException(
            'SEARCH_HTTP_ERROR',
            '搜索页面返回 HTTP ${response.statusCode}',
          );
        }
      },
    );
    final starting = browser!.run();
    unawaited(
      starting.then((_) async {
        if (finished) await disposeBrowser();
      }, onError: (Object _) {}),
    );
    await starting;
    while (!finished) {
      run.check();
      if (pageError != null) throw pageError!;
      final result = loaded
          ? await controller?.evaluateJavascript(source: _snapshot)
          : null;
      if (result is Map) {
        final location = Uri.tryParse(result['url'] as String? ?? '');
        if (location == null ||
            !agentSearchNavigationAllowed(location, engine)) {
          throw const AgentException('SEARCH_REDIRECT', '搜索页面跳转到了其他网站');
        }
        if (result['too_large'] == true) {
          throw const AgentException(
            'SEARCH_RESPONSE_TOO_LARGE',
            '搜索页面过大，请缩小搜索范围',
          );
        }
        if (result['html'] is String) return result['html'] as String;
      }
      await run.wait(Future<void>.delayed(const Duration(milliseconds: 400)));
    }
    throw const AgentException('CANCELLED', '已停止搜索');
  }

  try {
    return await run.wait(load(), timeout: const Duration(seconds: 20));
  } on AgentException {
    rethrow;
  } catch (_) {
    run.check();
    throw const AgentException(
      'SEARCH_BROWSER_UNAVAILABLE',
      '网页搜索组件不可用，请改用 Bing、Tavily 或 DeepSeek',
    );
  } finally {
    finished = true;
    await disposeBrowser();
    try {
      await environment?.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {
      // The platform may already have released its environment.
    }
  }
}

// Read only the result document; no clicking, challenge solving, application
// JavaScript handlers, or clearing cookies used by other application pages.
const _snapshot = r'''
(() => {
  if (document.readyState === 'loading') return null;
  const text = document.body ? document.body.innerText : '';
  const ready = document.querySelector(
    'a h3, .BNeawe.vvjwJb, li.b_algo, #captcha-form, #b_captcha, .g-recaptcha, form[action*="/sorry"]'
  ) || /did not match any documents|no results found|unusual traffic|没有找到|未找到|验证码|请完成验证/i.test(text);
  if (!ready) return null;
  const copy = document.documentElement.cloneNode(true);
  copy.querySelectorAll('script,style,noscript,svg').forEach(node => node.remove());
  const html = copy.outerHTML;
  return html.length > 2097152
    ? {url: location.href, too_large: true}
    : {url: location.href, html: html};
})();
''';
