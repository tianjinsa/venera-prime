import 'package:venera/utils/translations.dart';

Future<void>? _initialization;

/// Several widget suites share one isolate in an integration test application.
Future<void> ensureTestTranslations() {
  try {
    AppTranslation.translations;
    return Future<void>.value();
  } catch (_) {
    return _initialization ??= AppTranslation.init();
  }
}
