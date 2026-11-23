import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  final Map<String, String> env = Platform.environment;

  test('a plain value arrives as written', () {
    expect(env['PLAIN'], 'as written');
  });

  test(r'$(rlocationpath) expands to a path Runfiles resolves', () {
    final String path = Runfiles.create().rlocation(env['DATA_RLOCATIONPATH']!);
    expect(File(path).readAsStringSync().trim(), 'present');
  });
}
