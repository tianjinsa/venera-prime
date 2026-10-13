import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_maintenance_service.dart';
import 'package:venera/foundation/cache_manager.dart';

class _Cache implements CacheManager {
  int cleanups = 0;
  int days = -1;
  int limit = -1;
  Completer<void>? blocked;

  @override
  void setRetentionDays(int value) => days = value;
  @override
  void setLimitSize(int value) => limit = value;
  @override
  Future<CacheCleanupProgress> checkCache({
    void Function(CacheCleanupProgress)? onProgress,
  }) async {
    cleanups++;
    await blocked?.future;
    const progress = CacheCleanupProgress(1, 1, 1, 3);
    onProgress?.call(progress);
    return progress;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Object? oldRetention;
  late Object? oldLimit;
  setUp(() {
    oldRetention = appdata.settings['cacheRetentionDays'];
    oldLimit = appdata.settings['cacheSize'];
    appdata.settings['cacheRetentionDays'] = 3;
    appdata.settings['cacheSize'] = 50;
  });
  tearDown(() {
    appdata.settings['cacheRetentionDays'] = oldRetention;
    appdata.settings['cacheSize'] = oldLimit;
  });

  testWidgets(
    'startup, periodic, resume and changed policy all schedule maintenance',
    (tester) async {
      final cache = _Cache();
      final reasons = <String>[];
      final service = CacheMaintenanceService(
        manager: () => cache,
        interval: const Duration(minutes: 10),
      );
      addTearDown(service.stop);
      service.runTask = (reason, work) async {
        reasons.add(reason);
        await work();
      };
      service.start();
      service.start();
      await tester.pump();
      expect(reasons, ['startup']);
      expect(cache.days, 3);
      expect(cache.limit, 50);
      await tester.pump(const Duration(minutes: 10));
      expect(reasons.last, 'periodic');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(reasons.last, 'resumed');
      appdata.settings['cacheRetentionDays'] = 30;
      await tester.pump();
      expect(reasons.last, 'settings');
      expect(cache.days, 30);
      final count = cache.cleanups;
      appdata.settings['cacheRetentionDays'] = 30;
      await tester.pump();
      expect(cache.cleanups, count);
      service.stop();
      await tester.pump(const Duration(minutes: 20));
      expect(cache.cleanups, count);
    },
  );

  testWidgets(
    'a policy change during cleanup triggers a second pass without overlapping',
    (tester) async {
      final cache = _Cache()..blocked = Completer<void>();
      final service = CacheMaintenanceService(manager: () => cache);
      addTearDown(service.stop);
      service.start();
      await tester.pump();
      expect(cache.cleanups, 1);
      appdata.settings['cacheRetentionDays'] = 1;
      appdata.settings['cacheSize'] = 10;
      await tester.pump();
      expect(cache.cleanups, 1);
      cache.blocked!.complete();
      await tester.pump();
      expect(cache.cleanups, 2);
      expect(cache.days, 1);
      expect(cache.limit, 10);
      service.stop();
    },
  );
}
