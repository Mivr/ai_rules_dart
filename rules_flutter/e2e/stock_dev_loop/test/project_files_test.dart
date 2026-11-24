import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'config_marker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fixture under test/ is read by its path in the project', () {
    expect(
      File('test/fixtures/greeting.txt').readAsStringSync(),
      'hello from a fixture\n',
    );
  });

  test('flutter_test_config.dart wraps the test', () {
    expect(configuredBy, 'test/flutter_test_config.dart');
  });

  test("NOTICES holds the project's own licence", () async {
    final ByteData data = await rootBundle.load('NOTICES.Z');
    final String notices = utf8.decode(gzip.decode(data.buffer.asUint8List()));
    expect(
      notices,
      contains('counter\n\nThe licence of the stock_dev_loop example project.'),
    );
  });
}
