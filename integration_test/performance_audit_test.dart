import 'package:integration_test/integration_test.dart';

import '../test/http_connection_pool_test.dart' as network;
import '../test/image_favorites_local_test.dart' as favorites;
import '../test/support/performance_lists_cases.dart' as lists;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The Android integration-test application ID is separate from the app.
  // These cases use loopback HTTP and temporary files, without App.init().
  network.registerHttpConnectionPoolTests(device: true);
  favorites.registerImageFavoriteLocalTests(device: true);
  lists.registerListPerformanceTests(device: true);
}
