import 'package:integration_test/integration_test.dart';

import '../test/support/background_feature_cases.dart';

class _BackgroundFeaturesBinding extends IntegrationTestWidgetsFlutterBinding {
  // The percentage editor uses tester.enterText. Keep its input inside the
  // test harness instead of invoking the device owner's software keyboard.
  @override
  bool get registerTestTextInput => true;
}

void main() {
  _BackgroundFeaturesBinding();
  // Build/run only with the isolated .integrationtest application ID. This
  // entrypoint deliberately never invokes the real application's main/init.
  registerBackgroundFeatureTests();
}
