import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/batched_notifications.dart';

class _Notifier extends ChangeNotifier with BatchedNotifications {
  void change() => notifyListeners();
}

void main() {
  test('nested batches notify once, including changes before an exception', () {
    final notifier = _Notifier();
    var count = 0;
    notifier.addListener(() => count++);
    notifier.change();
    expect(count, 1);
    expect(
      () => notifier.batchNotifications<void>(() {
        notifier.change();
        notifier.batchNotifications(() {
          notifier.change();
        });
        expect(count, 1);
        throw StateError('partial failure');
      }),
      throwsStateError,
    );
    expect(count, 2);
    notifier.batchNotifications(() {});
    expect(count, 2);
    notifier.change();
    expect(count, 3);
    notifier.dispose();
  });
}
