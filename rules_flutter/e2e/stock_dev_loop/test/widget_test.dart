import 'package:counter_lib/counter_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the count reads as the other package formats it', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Text(describeCount(1))));
    expect(find.text('count 1 (${libMark()})'), findsOneWidget);
  });
}
