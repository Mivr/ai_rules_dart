import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final byCwd = File('dart/tests/test_cwd_fixture/data.txt');
  if (!byCwd.existsSync() || byCwd.readAsStringSync().trim() != 'present') {
    stderr.writeln(
      'direct_cwd_test: expected dart/tests/test_cwd_fixture/data.txt in cwd '
      '(${Directory.current.path})',
    );
    exit(1);
  }

  final byRunfiles = File(
    Runfiles.create().rlocation('_main/dart/tests/test_cwd_fixture/data.txt'),
  );
  if (!byRunfiles.existsSync() ||
      byRunfiles.readAsStringSync().trim() != 'present') {
    stderr.writeln(
      'direct_cwd_test: expected data.txt via Runfiles (${byRunfiles.path})',
    );
    exit(1);
  }
}
