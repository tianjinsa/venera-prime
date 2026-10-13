import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';

/// Owns automatic scheduling; the cache manager owns file safety and policy.
class CacheMaintenanceService with WidgetsBindingObserver {
  static final instance = CacheMaintenanceService();
  final CacheManager Function() _manager;
  final Duration interval;
  Timer? _timer;
  bool _started = false;
  int? _retention;
  int? _limit;
  Future<void>? _running;
  bool _rerun = false;

  /// Optional integration point for the app's background task center.
  /// The runner should await work and may supply an onProgress callback.
  Future<void> Function(
    String reason,
    Future<CacheCleanupProgress> Function({
      void Function(CacheCleanupProgress)? onProgress,
    })
    work,
  )?
  runTask;

  CacheMaintenanceService({
    CacheManager Function()? manager,
    this.interval = const Duration(hours: 1),
  }) : _manager = manager ?? CacheManager.new;

  void start() {
    if (_started) return;
    _started = true;
    _applySettings();
    appdata.settings.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(interval, (_) => _schedule('periodic'));
    _schedule('startup');
  }

  bool _applySettings() {
    final value = appdata.settings['cacheRetentionDays'];
    final retention = value is int && [0, 1, 3, 7, 30].contains(value)
        ? value
        : 7;
    final configuredLimit = appdata.settings['cacheSize'];
    final limit = configuredLimit is int && configuredLimit >= 0
        ? configuredLimit
        : 2048;
    final changed = retention != _retention || limit != _limit;
    _retention = retention;
    _limit = limit;
    _manager().setRetentionDays(retention);
    _manager().setLimitSize(limit);
    return changed;
  }

  void _onSettingsChanged() {
    if (_applySettings()) {
      _rerun = _running != null;
      _schedule('settings');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedule('resumed');
  }

  void _schedule(String reason) {
    unawaited(
      clean(reason: reason).catchError((Object error, StackTrace stack) {
        Log.error('Automatic cache cleanup', error, stack);
      }),
    );
  }

  Future<void> clean({String reason = 'manual'}) {
    if (_running != null) return _running!;
    final operation = _run(reason);
    _running = operation;
    return operation.whenComplete(() => _running = null);
  }

  Future<void> _run(String reason) async {
    do {
      _rerun = false;
      _applySettings();
      final runner = runTask;
      if (runner == null) {
        await _manager().checkCache();
      } else {
        await runner(reason, _manager().checkCache);
      }
      reason = 'settings';
    } while (_rerun);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    appdata.settings.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
  }
}
