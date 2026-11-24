// A test of a project in a subdirectory of the workspace (a path dependency
// of the stock project): it runs in this project's directory, as under
// `flutter test`, so the project-relative paths below are the ones stock
// reads.
import 'dart:convert';
import 'dart:io';

import 'package:counter_lib/counter_lib.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a default fixture is read by its path in the project', () {
    final Object? fixture = jsonDecode(
      File('test/fixtures/count.json').readAsStringSync(),
    );
    expect(
      describeCount((fixture! as Map<String, Object?>)['count']! as int),
      'count 3 (lib0)',
    );
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('name: counter_lib'),
    );
  });

  test('a golden is read by its path in the project', () {
    expect(File('test/goldens/square.png').existsSync(), isTrue);
  });

  testWidgets('a golden matches, relative to the test file', (tester) async {
    await tester.pumpWidget(
      const Center(
        child: RepaintBoundary(
          key: Key('square'),
          child: SizedBox(
            width: 16,
            height: 16,
            child: ColoredBox(color: Color(0xFF3366CC)),
          ),
        ),
      ),
    );
    await expectLater(
      find.byKey(const Key('square')),
      matchesGoldenFile('goldens/square.png'),
    );
  });
}
