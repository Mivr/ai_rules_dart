import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_home/main.dart' as app;

void main() {
  testWidgets('renders run_home label', (WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle();
    expect(find.text('run_home'), findsOneWidget);
  });
}
