import 'dart:async';

import 'config_marker.dart';

/// Wraps every test under `test/`, as `flutter test` wraps them.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  configuredBy = 'test/flutter_test_config.dart';
  await testMain();
}
