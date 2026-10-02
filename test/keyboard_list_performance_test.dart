import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/context.dart';

class _FailingCover extends ImageProvider<_FailingCover> {
  static int requests = 0;

  @override
  Future<_FailingCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingCover key,
    ImageDecoderCallback decode,
  ) {
    requests++;
    scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.error(StateError('offline')),
    );
  }
}

void main() {
  testWidgets(
    'size-only consumers ignore keyboard frames but react to resizing',
    (tester) async {
      var builds = 0;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              builds++;
              return SizedBox(width: context.width, height: context.height);
            },
          ),
        ),
      );
      final before = builds;
      for (var i = 1; i <= 15; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: i * 20.0);
        await tester.pump();
      }
      expect(builds, before);
      tester.view.physicalSize = const Size(600, 900);
      await tester.pump();
      expect(builds, before + 1);
    },
  );

  testWidgets(
    'navigation does not rebuild long page contents on keyboard frames',
    (tester) async {
      var pageBuilds = 0;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          home: NaviPane(
            observer: NaviObserver(),
            navigatorKey: GlobalKey<NavigatorState>(),
            paneItems: [
              PaneItemEntry(
                label: 'Favorites',
                icon: Icons.star_border,
                activeIcon: Icons.star,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) {
              pageBuilds++;
              return Scaffold(
                body: ListView.builder(
                  itemCount: 10000,
                  itemExtent: 80,
                  itemBuilder: (_, i) => Text('Comic $i'),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = pageBuilds;
      for (var i = 1; i <= 15; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: i * 20.0);
        await tester.pump();
      }
      expect(pageBuilds, before);
      expect(find.byType(Text).evaluate().length, lessThan(40));
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dependency changes do not restart a failed cover', (
    tester,
  ) async {
    _FailingCover.requests = 0;
    final provider = _FailingCover();
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, child) =>
              TickerMode(enabled: value, child: child!),
          child: AnimatedImage(image: provider, width: 80, height: 120),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_FailingCover.requests, 1);
    for (var i = 0; i < 5; i++) {
      enabled.value = !enabled.value;
      await tester.pump();
    }
    expect(_FailingCover.requests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
