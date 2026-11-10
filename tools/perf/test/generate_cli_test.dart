/// Tests for `generate --libraries` and its flag conflicts.
library;

import 'dart:io';

import 'package:perf/generate_cli.dart';
import 'package:perf/library_shape.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

Directory _rulesDir(Directory root) {
  final rules = Directory('${root.path}/rules')..createSync();
  File('${rules.path}/MODULE.bazel')
      .writeAsStringSync('module(name = "rules_dart")\n');
  return rules;
}

int _generate(Directory rules, String out, List<String> extra) =>
    runGenerateCli([
      '--target-loc=20000',
      '--seed=3',
      '--rules-dart=${rules.path}',
      '--out=$out',
      ...extra,
    ]);

int _packageCount(String out) =>
    Directory('$out/packages').listSync().whereType<Directory>().length;

/// Maps every file under [root] to its content, keyed by relative path.
Map<String, String> _snapshot(String root) {
  final prefix = root.length + 1;
  return {
    for (final f in Directory(root).listSync(recursive: true))
      if (f is File) f.path.substring(prefix): f.readAsStringSync(),
  };
}

void _testShapes() {
  for (final n in [2, 7, 32, 100, 1000, 5000]) {
    final shape = shapeForLibraries(n);
    _check(shape.libraries == n, '$n libraries -> ${shape.libraries}');
    _check(shape.layers >= 2, '$n has at least two layers');
    _check(shape.fanout >= 1 && shape.fanout <= 50, '$n fanout in 1..50');
  }
  final base = shapeForLibraries(32);
  _check(base.layers == 8 && base.fanout == 4, '32 keeps the 8 x 4 shape');
  try {
    shapeForLibraries(1);
    throw StateError('FAIL: 1 library must be rejected');
  } on ArgumentError {
    // Expected.
  }
}

void _testLibrariesFlag(Directory root, Directory rules) {
  for (final n in [32, 1000, 5000]) {
    final out = '${root.path}/out_$n';
    final code = _generate(rules, out, ['--libraries=$n']);
    _check(code == 0, '--libraries=$n exits 0, got $code');
    _check(_packageCount(out) == n, '--libraries=$n writes $n packages');
  }
}

void _testConflictsAndInvalid(Directory root, Directory rules) {
  for (final extra in [
    ['--libraries=32', '--layers=4'],
    ['--libraries=32', '--fanout=2'],
    ['--libraries=32', '--layers=8', '--fanout=4'],
    ['--libraries=1'],
    ['--libraries=abc'],
  ]) {
    final out = '${root.path}/out_bad';
    final code = _generate(rules, out, extra);
    _check(code == 1, '$extra exits 1, got $code');
    _check(!Directory(out).existsSync(), '$extra writes nothing');
  }
}

void _testUnchangedWithoutLibraries(Directory root, Directory rules) {
  final plain = '${root.path}/plain';
  final explicit = '${root.path}/explicit';
  final viaLibraries = '${root.path}/via_libraries';
  _check(_generate(rules, plain, []) == 0, 'default generate exits 0');
  _check(
    _generate(rules, explicit, ['--layers=8', '--fanout=4']) == 0,
    'explicit layers and fanout exit 0',
  );
  _check(
    _generate(rules, viaLibraries, ['--libraries=32']) == 0,
    '--libraries=32 exits 0',
  );
  final expected = _snapshot(plain);
  _check(expected.length > 32, 'default workspace has files');
  _check(
    _snapshot(explicit).toString() == expected.toString(),
    '--layers=8 --fanout=4 matches the default output',
  );
  _check(
    _snapshot(viaLibraries).toString() == expected.toString(),
    '--libraries=32 matches the 8 x 4 output',
  );
  _check(_packageCount(plain) == 32, 'default shape is 32 libraries');
}

void main() {
  _testShapes();
  final root = Directory.systemTemp.createTempSync('rd_gen_cli_');
  try {
    final rules = _rulesDir(root);
    _testLibrariesFlag(root, rules);
    _testConflictsAndInvalid(root, rules);
    _testUnchangedWithoutLibraries(root, rules);
  } finally {
    root.deleteSync(recursive: true);
  }
  stdout.writeln('Generate CLI tests passed.');
}
