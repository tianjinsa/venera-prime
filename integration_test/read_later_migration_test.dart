import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/data_backup_test.dart' as backup;
import '../test/read_later_test.dart' as read_later;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The Android test runner uses the isolated integrationtest application ID.
  group('Read later schema migration', read_later.main);
  group('Backup import and restart', backup.main);
}
