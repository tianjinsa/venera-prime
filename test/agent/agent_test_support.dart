import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

/// Exercise navigation at real phone sizes, including lazy settings lists.
Future<void> tapAgentSetting(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final target = find.byKey(ValueKey(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      250,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pump();
  await tester.tap(target);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
}
