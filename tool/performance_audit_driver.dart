import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) => writeResponseData(
    data,
    destinationDirectory: Platform.environment['PERFORMANCE_AUDIT_OUTPUT_DIR'],
    testOutputFilename: 'performance-audit-response',
  ),
);
