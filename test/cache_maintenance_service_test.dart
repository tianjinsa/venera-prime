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
  Object? failure;

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
    if (failure != null) throw failure!;
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
  late Map<String, dynamic> oldImplicitData;
  setUp(() {
    oldImplicitData = appdata.implicitData;
    appdata.implicitData = {};
    oldRetention = appdata.settings['cacheRetentionDays'];
    oldLimit = appdata.settings['cacheSize'];
    appdata.settings['cacheRetentionDays'] = 3;
    appdata.settings['cacheSize'] = 50;
  });
  tearDown(() {
    appdata.implicitData = oldImplicitData;
    appdata.settings['cacheRetentionDays'] = oldRetention;
    appdata.settings['cacheSize'] = oldLimit;
  });

  testWidgets(
    'automatic maintenance runs once per local day; policy changes bypass it',
    (tester) async {
      var now = DateTime(2026, 10, 14, 9);
      final cache = _Cache();
      final reasons = <String>[];
      final service = CacheMaintenanceService(
        manager: () => cache,
        interval: const Duration(minutes: 10),
        now: () => now,
        persist: () {},
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
      expect(reasons, ['startup']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(reasons, ['startup']);
      now = DateTime(2026, 10, 15, 0, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(reasons, ['startup', 'resumed']);
      await tester.pump(const Duration(minutes: 10));
      expect(cache.cleanups, 2);
      now = DateTime(2026, 10, 16, 0, 1);
      await tester.pump(const Duration(minutes: 10));
      expect(reasons.last, 'periodic');
      expect(cache.cleanups, 3);
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
      final service = CacheMaintenanceService(
        manager: () => cache,
        persist: () {},
      );
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

  test(
    'restarting the service does not repeat successful daily maintenance',
    () async {
      final cache = _Cache();
      var writes = 0;
      final now = DateTime(2026, 10, 14, 9);
      CacheMaintenanceService service() => CacheMaintenanceService(
        manager: () => cache,
        now: () => now,
        persist: () => writes++,
      );
      await service().clean(reason: 'startup');
      expect(writes, 1);
      final restarted = service();
      await restarted.clean(reason: 'startup');
      await restarted.clean(reason: 'resumed');
      expect(cache.cleanups, 1);
      await restarted.clean();
      expect(cache.cleanups, 2);
      expect(writes, 2);
    },
  );

  test(
    'a changed policy after restart is applied even on the same day',
    () async {
      final cache = _Cache();
      CacheMaintenanceService service() => CacheMaintenanceService(
        manager: () => cache,
        now: () => DateTime(2026, 10, 14, 9),
        persist: () {},
      );
      await service().clean(reason: 'startup');
      appdata.settings['cacheSize'] = 10;
      await service().clean(reason: 'startup');
      expect(cache.cleanups, 2);
      expect(cache.limit, 10);
    },
  );

  test(
    'failed maintenance stays retryable and overlapping calls share work',
    () async {
      final cache = _Cache()..failure = StateError('disk unavailable');
      var writes = 0;
      final service = CacheMaintenanceService(
        manager: () => cache,
        now: () => DateTime(2026, 10, 14, 9),
        persist: () => writes++,
      );
      await expectLater(service.clean(reason: 'startup'), throwsStateError);
      expect(writes, 0);
      expect(appdata.implicitData['cacheMaintenance'], isNull);
      cache.failure = null;
      cache.blocked = Completer<void>();
      final first = service.clean(reason: 'resumed');
      final second = service.clean(reason: 'periodic');
      expect(identical(first, second), isTrue);
      cache.blocked!.complete();
      await first;
      expect(cache.cleanups, 2);
      expect(writes, 1);
      await service.clean(reason: 'resumed');
      expect(cache.cleanups, 2);
    },
  );

  test('invalid or future daily records do not prevent maintenance', () async {
    final cache = _Cache();
    final service = CacheMaintenanceService(
      manager: () => cache,
      now: () => DateTime(2026, 10, 14, 9),
      persist: () {},
    );
    for (final timestamp in [
      'bad',
      999999999999999999,
      DateTime(2026, 10, 15).millisecondsSinceEpoch,
    ]) {
      appdata.implicitData['cacheMaintenance'] = {
        'finishedAt': timestamp,
        'retentionDays': 3,
        'limitSize': 50,
      };
      await service.clean(reason: 'startup');
    }
    expect(cache.cleanups, 3);
  });
}
