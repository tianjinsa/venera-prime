import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// Shares cover requests across providers and bounds weak-network work.
class ThumbnailRequestQueue {
  ThumbnailRequestQueue({
    this.maxConcurrent = 6,
    this.failureCooldown = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : assert(maxConcurrent > 0),
       _now = now ?? DateTime.now;

  final int maxConcurrent;
  final Duration failureCooldown;
  final DateTime Function() _now;
  final _pending = <String, _ThumbnailRequest>{};
  final _failures = <String, (DateTime, Object, StackTrace)>{};
  final _waiters = Queue<Completer<void>>();
  int _active = 0;

  Future<Uint8List> load(
    String key,
    Future<Uint8List> Function() loader, {
    bool Function()? isCancelled,
  }) {
    final cancelled = isCancelled ?? () => false;
    final pending = _pending[key];
    if (pending != null) {
      pending.consumers.add(cancelled);
      return pending.result;
    }
    final failure = _failures[key];
    if (failure != null && _now().difference(failure.$1) < failureCooldown) {
      return Future.error(failure.$2, failure.$3);
    }
    _failures.remove(key);
    final request = _ThumbnailRequest()..consumers.add(cancelled);
    request.result = Future<Uint8List>.microtask(
      () => _run(key, request, loader),
    );
    _pending[key] = request;
    return request.result;
  }

  Future<Uint8List> _run(
    String key,
    _ThumbnailRequest request,
    Future<Uint8List> Function() loader,
  ) async {
    if (_active >= maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      if (request.consumers.every((cancelled) => cancelled())) {
        throw const ThumbnailRequestCancelled();
      }
      return await loader();
    } on ThumbnailRequestCancelled {
      rethrow;
    } catch (error, stack) {
      _failures[key] = (_now(), error, stack);
      // Failed URLs must not accumulate for an entire browsing session.
      while (_failures.length > 256) {
        _failures.remove(_failures.keys.first);
      }
      rethrow;
    } finally {
      _pending.remove(key);
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}

class _ThumbnailRequest {
  final consumers = <bool Function()>[];
  late final Future<Uint8List> result;
}

class ThumbnailRequestCancelled implements Exception {
  const ThumbnailRequestCancelled();
}
