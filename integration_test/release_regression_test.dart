import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

import '../test/explore_initialization_test.dart' as explore;
import '../test/support/data_sync_cases.dart';
import '../test/support/follow_updates_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Isolated application only. These cases use temporary databases, fake comic
  // sources and a loopback WebDAV server, never the user's settings or library.
  group('Follow updates', () {
    // These minimal follow fixtures do not implement explore callbacks. Do not
    // leak them into the next suite sharing this integration-test isolate.
    tearDown(() {
      final manager = ComicSourceManager();
      for (final source in manager.all()) {
        manager.remove(source.key);
      }
    });
    registerFollowUpdatesTests();
  });
  group('Explore initialization', explore.main);
  group('WebDAV', () => registerDataSyncTransportTests(device: true));
}
