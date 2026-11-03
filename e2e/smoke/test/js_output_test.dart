import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Checks the compiled JS from `dart_js_binary` exists and carries the source.
void main() {
  test('dart_js_binary output is non-empty and has the marker', () {
    final r = Runfiles.create();
    final file = File(r.rlocation('_main/web_app.js'));
    expect(file.existsSync(), isTrue);
    final js = file.readAsStringSync();
    expect(js, isNotEmpty);
    expect(js, contains('smoke-js-marker:'));
  });
}
