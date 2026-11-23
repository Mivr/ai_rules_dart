import 'package:flutter_test/flutter_test.dart';
import 'package:integration_ios/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:spm_objc_plugin/spm_objc_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('builds the plugin ObjC target beside its Swift target', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();

    // The Swift target imports the separate ObjC module and reads the
    // value only that module computes, so this assertion fails when the
    // manifest's second target is not compiled.
    expect(await const SpmObjcPlugin().computedValue(), '149');
  });
}
