import 'package:integration_test/integration_test.dart';
import '../test/support/avif_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerAvifTests(device: true);
}
