/// Tripwire: `flutter/private/layering_check.bzl` is the only Flutter file
/// that loads rules_dart's `import_check.bzl`, and nothing loads a
/// `dart/private` file of rules_dart for the check. The iOS integration test's
/// generated-bootstrap application is the one target built with it off.
///
/// One wiring means the checked rules cannot drift apart and the later rules
/// adopt the check by loading the helper. The test reads the live tree, found
/// through its own source file in `data`, hence the `external` tag.
library;

import 'dart:io';

import 'package:test/test.dart';

const String _helper = 'flutter/private/layering_check.bzl';

/// Workspace root: first ancestor of the test's runfiles anchor that holds
/// `flutter/` and `MODULE.bazel`.
String _findRoot() {
  final String? anchor = Platform.environment['LAYERING_GUARD_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor == null || anchor.isEmpty || srcdir == null) {
    throw StateError('LAYERING_GUARD_ANCHOR or TEST_SRCDIR is unset');
  }
  Directory dir = Directory(
    File('$srcdir/$anchor').resolveSymbolicLinksSync(),
  ).parent;
  for (var i = 0; i < 8; i++) {
    if (Directory('${dir.path}/flutter').existsSync() &&
        File('${dir.path}/MODULE.bazel').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  throw StateError('workspace root not found above $anchor');
}

/// Every `.bzl` file under `flutter/`, as workspace-relative paths.
List<String> _bzlFiles(String root) =>
    Directory('$root/flutter')
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.bzl'))
        .map((File f) => f.path.substring(root.length + 1))
        .toList()
      ..sort();

/// The load statements of [source] whose label matches [label].
bool _loads(String source, RegExp label) => RegExp(
  r'^load\(\s*"([^"]+)"',
  multiLine: true,
).allMatches(source).any((RegExpMatch m) => label.hasMatch(m.group(1)!));

void main() {
  final String root = _findRoot();
  final List<String> files = _bzlFiles(root);

  test('the helper loads the public import_check.bzl', () {
    final String source = File('$root/$_helper').readAsStringSync();
    expect(
      _loads(source, RegExp(r'^@rules_dart//dart:import_check\.bzl$')),
      isTrue,
    );
  });

  test('no other Flutter file loads import_check.bzl', () {
    final List<String> loaders = files
        .where(
          (String f) =>
              f != _helper &&
              _loads(
                File('$root/$f').readAsStringSync(),
                RegExp(r'import_check\.bzl$'),
              ),
        )
        .toList();
    expect(loaders, isEmpty, reason: 'load the check through $_helper');
  });

  test('no Flutter file loads a rules_dart private file', () {
    final List<String> loaders = files
        .where(
          (String f) => _loads(
            File('$root/$f').readAsStringSync(),
            RegExp('^@rules_dart//dart/private'),
          ),
        )
        .toList();
    expect(loaders, isEmpty);
  });

  test('the iOS integration bootstrap application is the unchecked one', () {
    final String source = File(
      '$root/flutter/private/flutter_integration_test_ios.bzl',
    ).readAsStringSync();
    final RegExpMatch? call = RegExp(
      r'_flutter_application\((.*?)\n    \)',
      dotAll: true,
    ).firstMatch(source);
    expect(call, isNotNull, reason: 'the internal flutter_application call');
    expect(call!.group(1), contains('features = ["-dart_layering_check"]'));
  });
}
