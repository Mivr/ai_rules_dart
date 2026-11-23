import 'package:args/args.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_plugin/hello_plugin.dart';

void main() {
  testWidgets('a git package and a path plugin build into one test', (tester) async {
    final parser = ArgParser()..addOption('name');
    final name = parser.parse(['--name', 'git'])['name'] as String;
    await tester.pumpWidget(Text(hello(name), textDirection: TextDirection.ltr));
    expect(find.text('hello, git'), findsOneWidget);
  });
}
