import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';

/// Owns the cache budget for one reader session, including its async estimate.
class ReaderImageCache {
  ReaderImageCache({
    ImageCache? cache,
    Future<int?> Function()? availableMemory,
  }) : _cache = cache ?? PaintingBinding.instance.imageCache,
       _availableMemory =
           availableMemory ?? MemoryInfo.getFreePhysicalMemorySize,
       _generation = ++_currentGeneration {
    _restoreTimer?.cancel();
    _restoreTimer = null;
  }

  static int _currentGeneration = 0;
  static Timer? _restoreTimer;
  static const _normalBudget = 100 << 20;
  static const _pressureBudget = 32 << 20;
  final ImageCache _cache;
  final Future<int?> Function() _availableMemory;
  final int _generation;
  bool _disposed = false;
  bool _underPressure = false;

  bool get _isCurrent => !_disposed && _generation == _currentGeneration;

  /// Low-memory sessions load the visible page without decoding extra pages.
  bool get allowPrecache =>
      _isCurrent && !_underPressure && _cache.maximumSizeBytes >= 64 << 20;

  Future<void> configure() async {
    try {
      final available = await _availableMemory();
      if (!_isCurrent ||
          _underPressure ||
          available == null ||
          available <= 0) {
        return;
      }
      // Keep at most a small fraction of currently available RAM as reusable
      // decoded images. Visible images can also be retained outside this cache.
      _cache.maximumSizeBytes = (available ~/ 16).clamp(32 << 20, 192 << 20);
    } catch (_) {
      // Memory information is optional on unsupported platforms.
    }
  }

  void handleMemoryPressure() {
    if (!_isCurrent) return;
    _underPressure = true;
    _cache.maximumSizeBytes = math.min(
      _cache.maximumSizeBytes,
      _pressureBudget,
    );
  }

  void dispose() {
    final wasCurrent = _isCurrent;
    _disposed = true;
    if (!wasCurrent) return;
    // A quick return to the same reader should reuse decoded pages. Avoid
    // evicting many images during the route's closing frame.
    _restoreTimer = Timer(const Duration(seconds: 1), () {
      _restoreTimer = null;
      if (_generation != _currentGeneration) return;
      _cache.maximumSizeBytes = math.min(
        _cache.maximumSizeBytes,
        _normalBudget,
      );
    });
  }
}
