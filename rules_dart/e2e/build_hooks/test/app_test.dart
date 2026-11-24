// Runs the AOT-compiled app, which loads its libraries from the directory
// beside it, and reads what the link hook made of its recorded uses.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _rlocation(String path) {
  final dir = Platform.environment['RUNFILES_DIR'];
  return dir == null ? path : '$dir/$path';
}

void main(List<String> args) {
  test('the app runs with every library its hooks built', () {
    final result = Process.runSync(_rlocation(args[0]), const []);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      LineSplitter.split(result.stdout as String),
      ['sqlite 3.53.4', 'add 5', 'times 42'],
    );
  });

  test('the link hook saw the one constant Factor', () {
    final factors = jsonDecode(File(_rlocation(args[1])).readAsStringSync());
    expect(factors, [6]);
  });
}
