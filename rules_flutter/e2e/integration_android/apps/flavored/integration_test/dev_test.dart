/// Integration test for the dev flavor.
library;

import 'package:flavored/main.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<String> _assetText(String key) async =>
    (await rootBundle.loadString(key)).replaceAll('\r\n', '\n');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dev flavor sets appFlavor and bundles only dev assets', (
    tester,
  ) async {
    await tester.pumpWidget(const FlavoredApp());
    await tester.pumpAndSettle();

    expect(appFlavor, equals('dev'));
    expect(
      await _assetText('packages/flavor_assets/assets/dev_asset.txt'),
      equals('dev asset\n'),
    );
    expect(
      () =>
          rootBundle.loadString('packages/flavor_assets/assets/prod_asset.txt'),
      throwsA(isA<FlutterError>()),
    );
  });
}
