import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

import 'reader_page_margin_test.dart' as fixture;

class _NoDataSync extends Fake implements DataSync {
  @override
  void onDataChanged() {}

  @override
  Future<Res<bool>> uploadData({bool force = false}) async => const Res(true);
}

void main() {
  late DataSync? previousSync;
  setUp(() {
    previousSync = DataSync.instance;
    DataSync.instance = _NoDataSync();
  });
  tearDown(() => DataSync.instance = previousSync);

  testWidgets(
    'reader sidebar previews and persists line enhancement controls',
    (tester) async {
      final dynamic reader = await fixture.openReader(
        tester,
        'galleryLeftToRight',
      );
      final gallery = tester.widget<PhotoViewGallery>(
        find.byType(PhotoViewGallery),
      );
      final controller = gallery.pageController!;
      final page = reader.page;
      await tester.tapAt(tester.getRect(find.byType(Reader)).center);
      await fixture.settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await fixture.settle(tester);
      final settings = find.byType(ReaderSettings);
      final scrollable = find
          .descendant(of: settings, matching: find.byType(Scrollable))
          .first;
      final title = find.text('Line enhancement'.tl);
      await tester.scrollUntilVisible(title, 120, scrollable: scrollable);
      final tile = find.ancestor(of: title, matching: find.byType(ListTile));
      final toggle = find.descendant(of: tile, matching: find.byType(Switch));
      await Scrollable.ensureVisible(tester.element(toggle), alignment: 0.5);
      await fixture.settle(tester);
      await tester.tap(toggle);
      await fixture.settle(tester);
      expect(appdata.settings['readerLineEnhancement'], true);
      expect(tester.layers.whereType<ColorFilterLayer>(), isNotEmpty);

      final strengthTitle = find.text('Line enhancement strength'.tl);
      await tester.scrollUntilVisible(
        strengthTitle,
        100,
        scrollable: scrollable,
      );
      final strengthTile = find.ancestor(
        of: strengthTitle,
        matching: find.byType(ListTile),
      );
      final slider = find.descendant(
        of: strengthTile,
        matching: find.byType(Slider),
      );
      await Scrollable.ensureVisible(tester.element(slider), alignment: 0.5);
      await fixture.settle(tester);
      await tester.drag(slider, const Offset(60, 0));
      await fixture.settle(tester);
      expect(
        appdata.settings['readerLineEnhancementStrength'],
        greaterThan(0.5),
      );

      Navigator.of(tester.element(settings)).pop();
      await fixture.settle(tester);
      expect(reader.page, page);
      expect(
        tester
            .widget<PhotoViewGallery>(find.byType(PhotoViewGallery))
            .pageController,
        same(controller),
      );
      expect(controller.page, page);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await fixture.settle(tester);
    },
  );
}
