import 'package:flutter_test/flutter_test.dart';
import 'package:integration_ios/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:spm_graph_plugin/spm_graph_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('links the transitive SwiftPM graph and computes 6 and e', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();

    // Computed at run time by the transitive graph linked into the
    // plugin's Apple library: 2-combinations of four items
    // (swift-algorithms), then e (swift-numerics over its C shims).
    expect(await const SpmGraphPlugin().computeGraph(), '6 2.718281828459045');
  });
}
