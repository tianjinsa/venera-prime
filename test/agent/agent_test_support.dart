import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';

/// Never let storage tests discover a real user's application directory.
void configureAgentTestPaths(String path) {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = path;
  App.cachePath = path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => path,
      );
}
