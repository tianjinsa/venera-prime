import 'package:integration_test/integration_test.dart';

import '../test/support/performance_lists_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerListPerformanceTests(device: true);
}
