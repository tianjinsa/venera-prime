import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/update_schedule.dart';

void main() {
  final now = DateTime.utc(2026, 10, 13, 12);
  Map<String, Object> record(String status, Duration ago) => {
    'status': status,
    'finishedAt': now.subtract(ago).millisecondsSinceEpoch,
  };

  test('disabled startup check never becomes a completed attempt', () {
    expect(isUpdateCheckDue(now: now, enabled: false), isFalse);
    expect(isUpdateCheckDue(now: now), isTrue);
  });

  test('successful completion uses a full daily interval', () {
    expect(
      isUpdateCheckDue(
        now: now,
        checkRecord: record('completed', const Duration(hours: 23)),
      ),
      isFalse,
    );
    expect(
      isUpdateCheckDue(
        now: now,
        checkRecord: record('completed', const Duration(days: 1)),
      ),
      isTrue,
    );
  });

  test('failure and cancellation retry after an hour, not immediately', () {
    for (final status in ['failed', 'cancelled']) {
      expect(
        isUpdateCheckDue(
          now: now,
          checkRecord: record(status, const Duration(minutes: 59)),
        ),
        isFalse,
      );
      expect(
        isUpdateCheckDue(
          now: now,
          checkRecord: record(status, const Duration(hours: 1)),
        ),
        isTrue,
      );
    }
  });

  test(
    'failed script application shortens a successful catalog check gate',
    () {
      final check = record('completed', const Duration(hours: 2));
      expect(
        isUpdateCheckDue(
          now: now,
          checkRecord: check,
          applicationRecord: record('failed', const Duration(minutes: 30)),
        ),
        isFalse,
      );
      expect(
        isUpdateCheckDue(
          now: now,
          checkRecord: check,
          applicationRecord: record('failed', const Duration(minutes: 90)),
        ),
        isTrue,
      );
    },
  );

  test(
    'a newer manual check cannot hide still-pending installation failures',
    () {
      expect(
        isUpdateCheckDue(
          now: now,
          checkRecord: record('completed', const Duration(minutes: 30)),
          applicationRecord: record('failed', const Duration(minutes: 90)),
          hasPendingApplications: true,
        ),
        isTrue,
      );
    },
  );

  test(
    'a later successful check without pending updates does not retry forever',
    () {
      expect(
        isUpdateCheckDue(
          now: now,
          checkRecord: record('completed', const Duration(minutes: 30)),
          applicationRecord: record('failed', const Duration(days: 7)),
        ),
        isFalse,
      );
      expect(
        isUpdateCheckDue(
          now: now,
          checkRecord: record('completed', const Duration(minutes: 30)),
          applicationRecord: record('completed', const Duration(days: 7)),
        ),
        isFalse,
      );
    },
  );

  test(
    'initialization shares attempts, retries failure only on demand, and caches success',
    () async {
      final initialization = RetryableInitialization();
      final gate = Completer<void>();
      var attempts = 0;
      Future<void> initialize() {
        attempts++;
        return gate.future;
      }

      final first = initialization.run(initialize);
      final second = initialization.run(initialize);
      expect(identical(first, second), isTrue);
      expect(attempts, 1);
      final failed = expectLater(first, throwsStateError);
      gate.completeError(StateError('native runtime unavailable'));
      await failed;
      expect(initialization.isInitialized, isFalse);
      expect(initialization.isRunning, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
      await initialization.run(() async => attempts++);
      expect(initialization.isInitialized, isTrue);
      await initialization.run(() async => attempts++);
      expect(attempts, 2);
    },
  );

  test(
    'a synchronous initializer failure does not poison the retry cache',
    () async {
      final initialization = RetryableInitialization();
      await expectLater(
        initialization.run(() => throw StateError('failed')),
        throwsStateError,
      );
      expect(initialization.isRunning, isFalse);
      await initialization.run(() async {});
      expect(initialization.isInitialized, isTrue);
    },
  );
}
