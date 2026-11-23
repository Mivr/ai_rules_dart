/// Integration test for the prod flavor on the iOS simulator.
library;

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_ios/main.dart';
import 'package:integration_test/integration_test.dart';

Future<String> _assetText(String key) async =>
    (await rootBundle.loadString(key)).replaceAll('\r\n', '\n');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('prod flavor sets appFlavor and bundles only prod assets', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();

    expect(appFlavor, equals('prod'));
    expect(
      await _assetText('packages/flavor_assets/assets/prod_asset.txt'),
      equals('prod asset\n'),
    );
    expect(
      () =>
          rootBundle.loadString('packages/flavor_assets/assets/dev_asset.txt'),
      throwsA(isA<FlutterError>()),
    );
  });
}
