import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('landscape side navigation fits a short viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2340, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 8),
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: NaviPane(
          observer: NaviObserver(),
          navigatorKey: GlobalKey<NavigatorState>(),
          paneItems: [
            for (var i = 0; i < 4; i++)
              PaneItemEntry(
                label: 'Page $i',
                icon: Icons.circle_outlined,
                activeIcon: Icons.circle,
              ),
          ],
          paneActions: [
            for (var i = 0; i < 3; i++)
              PaneActionEntry(
                label: 'Action $i',
                icon: Icons.settings,
                onTap: () {},
              ),
          ],
          pageBuilder: (_) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
