import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pod_bigint_plugin/pod_bigint_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('links the plugin CocoaPods pod and computes 2^100', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('pod bigint test'))),
    );
    await tester.pumpAndSettle();

    // Computed at run time by the BigInt pod linked into the plugin's Apple
    // library: 2^100, then BigInt("-0").
    expect(
      await const PodBigintPlugin().computeBig(),
      '1267650600228229401496703205376 0',
    );
  });
}
