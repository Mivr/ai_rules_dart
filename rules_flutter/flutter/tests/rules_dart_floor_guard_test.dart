/// Tripwire: the floor in `flutter/private/rules_dart_floor.bzl` must equal
/// the `ai_rules_dart` floor in the root `MODULE.bazel`.
///
/// Bzlmod ignores `bazel_dep` versions for overridden modules, so the floor
/// file is what refuses an older `ai_rules_dart`. When the two disagree the
/// extension either refuses a supported release or fetches an unsupported
/// one. The test reads both files from the workspace root, found through the
/// test's own source file in `data` (an unsandboxed runfiles tree symlinks it
/// into the source tree; the root is the first ancestor holding `flutter/`
/// and `MODULE.bazel`), hence the `external` tag so it never serves a stale
/// pass.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Workspace root: first ancestor of the test's runfiles anchor that looks
/// like the rules_flutter checkout. Throws instead of passing silently when
/// neither the anchor nor the root resolves.
String _findRoot() {
  final String? anchor = Platform.environment['FLOOR_GUARD_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor == null || anchor.isEmpty || srcdir == null) {
    throw StateError('FLOOR_GUARD_ANCHOR or TEST_SRCDIR is unset');
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

void main() {
  test('rules_dart floor matches MODULE.bazel', () {
    final String root = _findRoot();
    final String module = File('$root/MODULE.bazel').readAsStringSync();
    final String floorSrc = File(
      '$root/flutter/private/rules_dart_floor.bzl',
    ).readAsStringSync();
    final String? dep = RegExp(
      'bazel_dep\\(name = "ai_rules_dart", version = "([^"]+)"',
    ).firstMatch(module)?.group(1);
    final String? pin = RegExp(
      'RULES_DART_FLOOR = "([^"]+)"',
    ).firstMatch(floorSrc)?.group(1);
    expect(dep, isNotNull, reason: 'ai_rules_dart bazel_dep missing');
    expect(pin, equals(dep), reason: 'floor file disagrees with MODULE.bazel');
  });
}
