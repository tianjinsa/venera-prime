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

  testWidgets(
    'foldable settings fills its touch target above the system bar after resize',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 24, bottom: 80),
              viewPadding: const EdgeInsets.only(top: 24, bottom: 80),
            ),
            child: child!,
          ),
          home: NaviPane(
            observer: NaviObserver(),
            navigatorKey: GlobalKey<NavigatorState>(),
            paneItems: [
              PaneItemEntry(
                label: 'Home',
                icon: Icons.home,
                activeIcon: Icons.home,
              ),
            ],
            paneActions: [
              PaneActionEntry(
                label: 'Settings',
                icon: Icons.settings,
                onTap: () => taps++,
              ),
            ],
            pageBuilder: (_) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final size in [
        const Size(900, 1000),
        const Size(1000, 700),
        const Size(900, 1000),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final target = find
            .ancestor(
              of: find.byIcon(Icons.settings),
              matching: find.byType(InkWell),
            )
            .first;
        final rect = tester.getRect(target);
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.bottom, lessThanOrEqualTo(size.height - 80));
        final before = taps;
        for (final point in [
          rect.topLeft + const Offset(2, 2),
          rect.bottomRight - const Offset(2, 2),
          rect.center,
        ]) {
          await tester.tapAt(point);
          await tester.pumpAndSettle();
        }
        expect(taps, before + 3);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
