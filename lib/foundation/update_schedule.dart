/// Uses actual completion records, not an attempt timestamp written before a
/// request. A recent script-install failure can shorten a successful catalog
/// check's daily interval.
bool isUpdateCheckDue({
  required DateTime now,
  bool enabled = true,
  Object? checkRecord,
  Object? applicationRecord,
  bool hasPendingApplications = false,
  Duration successInterval = const Duration(days: 1),
  Duration retryInterval = const Duration(hours: 1),
}) {
  if (!enabled) return false;
  final checked = _finishedAt(checkRecord);
  if (checked == null) return true;
  final success = checkRecord is Map && checkRecord['status'] == 'completed';
  var next = checked.add(success ? successInterval : retryInterval);
  final applied = _finishedAt(applicationRecord);
  if (applicationRecord is Map &&
      applied != null &&
      (applicationRecord['status'] == 'failed' ||
          applicationRecord['status'] == 'cancelled') &&
      (!applied.isBefore(checked) || hasPendingApplications)) {
    final retry = applied.add(retryInterval);
    if (retry.isBefore(next)) next = retry;
  }
  return !now.isBefore(next);
}

DateTime? _finishedAt(Object? record) {
  final value = record is Map ? record['finishedAt'] : null;
  if (value is! int) return null;
  try {
    return DateTime.fromMillisecondsSinceEpoch(value);
  } on ArgumentError {
    return null;
  }
}

/// Shares one attempt and caches only success. Retrying is caller-driven, so a
/// failure cannot schedule an unbounded immediate retry loop.
class RetryableInitialization {
  Future<void>? _pending;
  bool _initialized = false;
  bool get isInitialized => _initialized;
  bool get isRunning => _pending != null;

  Future<void> run(Future<void> Function() initialize) {
    if (_initialized) return Future<void>.value();
    return _pending ??= _attempt(initialize);
  }

  Future<void> _attempt(Future<void> Function() initialize) async {
    try {
      await Future<void>.sync(initialize);
      _initialized = true;
    } finally {
      _pending = null;
    }
  }
}
