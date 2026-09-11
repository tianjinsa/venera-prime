import 'package:flutter/foundation.dart';

/// Coalesces notifications while existing synchronous mutations run.
/// This does not change persistence or roll back partially successful actions.
mixin BatchedNotifications on ChangeNotifier {
  int _notificationDepth = 0;
  bool _notificationPending = false;

  T batchNotifications<T>(T Function() action) {
    _notificationDepth++;
    try {
      final result = action();
      if (result is Future) {
        throw ArgumentError('batchNotifications requires a synchronous action');
      }
      return result;
    } finally {
      _notificationDepth--;
      if (_notificationDepth == 0 && _notificationPending) {
        _notificationPending = false;
        super.notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    if (_notificationDepth > 0) {
      _notificationPending = true;
    } else {
      super.notifyListeners();
    }
  }
}
