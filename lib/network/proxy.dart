import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;
String? _cachedSetting;

Future<String?> getProxy() async {
  final setting = appdata.settings['proxy']?.toString() ?? 'system';
  if (_cachedSetting == setting &&
      _cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedSetting = setting;
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<String?> _getProxy() async {
  final configuredProxy = appdata.settings['proxy']?.toString() ?? 'system';
  if (configuredProxy.removeAllBlank == "direct") {
    return null;
  }
  if (configuredProxy != "system") {
    final proxy = _normalizeProxy(configuredProxy);
    if (proxy != null) return proxy;
    // Invalid persisted proxy settings must not prevent normal networking.
    return null;
  }

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return _normalizeProxy(proxy.substring(6));
      }
    }
  }

  return _normalizeProxy(res);
}

String? _normalizeProxy(String value) {
  final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.port <= 0 ||
      uri.port > 65535 ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri.replace(path: '').toString();
}

/// Dart's proxy resolver requires HOST:PORT, unlike the URL used by rhttp.
HttpClient createProxyHttpClient(String? proxy) {
  final client = HttpClient();
  final uri = proxy == null ? null : Uri.parse(proxy);
  client.findProxy = (_) {
    if (uri == null) return 'DIRECT';
    final host = uri.host.contains(':') && !uri.host.startsWith('[')
        ? '[${uri.host}]'
        : uri.host;
    return 'PROXY $host:${uri.port}';
  };
  if (uri != null && uri.userInfo.isNotEmpty) {
    final separator = uri.userInfo.indexOf(':');
    final username = Uri.decodeComponent(
      separator < 0 ? uri.userInfo : uri.userInfo.substring(0, separator),
    );
    final password = separator < 0
        ? ''
        : Uri.decodeComponent(uri.userInfo.substring(separator + 1));
    final attempted = <String>{};
    client.authenticateProxy = (host, port, scheme, realm) async {
      if (host != uri.host ||
          port != uri.port ||
          !attempted.add('$host:$port:$realm')) {
        return false;
      }
      client.addProxyCredentials(
        host,
        port,
        realm ?? '',
        HttpClientBasicCredentials(username, password),
      );
      return true;
    };
  }
  return client;
}
